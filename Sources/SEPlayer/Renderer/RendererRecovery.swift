import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import SEPlayerCommon
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

/// Expected output invalidations are distinct from terminal playback errors.
public enum RendererRecoveryReason: Int {
    case automaticFlush
    case decoderRequiresFlush
    /// The output failed for a reason of its own, not of the media: it was interrupted, or the system took its decoder
    /// away, as in the background.
    case outputFailed
    case outputConfigurationChanged
    case recoveryTimedOut
    case mediaServicesWereReset
}

public struct RendererRecoveryContext: Equatable {
    public let generation: UInt64
    public let mediaPeriodId: MediaPeriodId?

    public init(generation: UInt64, mediaPeriodId: MediaPeriodId?) {
        self.generation = generation
        self.mediaPeriodId = mediaPeriodId
    }
}

public struct RendererRecoveryRequest {
    public let reason: RendererRecoveryReason
    public let context: RendererRecoveryContext
    public let underlyingError: Error?
    /// Renderer time to restart from in a coordinated recovery, or `.invalid` for the current position.
    public let position: CMTime

    public init(
        reason: RendererRecoveryReason,
        context: RendererRecoveryContext,
        underlyingError: Error? = nil,
        position: CMTime = .invalid
    ) {
        self.reason = reason
        self.context = context
        self.underlyingError = underlyingError
        self.position = position
    }
}

enum RendererRecoveryError: Error {
    case timedOut
    case positionUnavailable
    case unsupportedAudioDecoding
}

/// What a renderer failure says about the media.
///
/// Only media that can't be decoded ends playback: whatever else fails is the output's own trouble, and a flush or a
/// seek to the current position gets past it.
enum RendererFailure: Equatable {
    /// The media can't be decoded: playing on would fail the same way.
    case decoding
    /// The output failed for a reason of its own: interrupted, reset, or its decoder taken away in the background.
    case output

    /// - Parameter isAppAway: Whether the app is in the background or just came back, when outputs fail whatever
    ///   they decode.
    init(_ error: Error, isAppAway: Bool = ApplicationActivity.shared.isAwayOrReturning()) {
        let chain = Self.errorChain(error)
        if isAppAway || chain.contains(where: Self.isOutputError) {
            self = .output
        } else {
            self = chain.contains(where: Self.isDecodingError) ? .decoding : .output
        }
    }

    /// The error and the errors it wraps, outermost first.
    private static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: Error? = error
        while let error = next, chain.count < 8 {
            if let playbackError = error as? SEPlaybackError {
                next = playbackError.underlyingError
                continue
            }
            if case RendererRecoveryError.unsupportedAudioDecoding = error {
                chain.append(NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioConverterErr_FormatNotSupported)))
                break
            }
            let nsError = error as NSError
            chain.append(nsError)
            next = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return chain
    }

    private static func isOutputError(_ error: NSError) -> Bool {
        switch error.domain {
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: error.code) {
            case .operationInterrupted?, .mediaServicesWereReset?, .decoderTemporarilyUnavailable?: return true
            default: return false
            }
        case NSOSStatusErrorDomain:
            return [kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr, kVTVideoDecoderNotAvailableNowErr,
                    kVTVideoDecoderReferenceMissingErr].contains(OSStatus(error.code))
        default:
            return false
        }
    }

    private static func isDecodingError(_ error: NSError) -> Bool {
        switch error.domain {
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: error.code) {
            case .decodeFailed?, .decoderNotFound?, .failedToParse?, .fileFormatNotRecognized?: return true
            default: return false
            }
        case NSOSStatusErrorDomain:
            return [kVTVideoDecoderBadDataErr, kVTVideoDecoderUnsupportedDataFormatErr, kVTCouldNotFindVideoDecoderErr,
                    kAudioConverterErr_FormatNotSupported].contains(OSStatus(error.code))
        default:
            return false
        }
    }
}

/// Spaces out coordinated recoveries that follow each other, so an output that keeps failing doesn't keep the player
/// seeking. Ordinary rate-change flushes don't count.
struct RendererRecoveryBackoff {
    private var attempts: [DispatchTime] = []

    /// Records an attempt at `now` and returns how long it waits: nothing for the first few in a while, then twice as
    /// long each time, up to a limit.
    mutating func delay(at now: DispatchTime = .now()) -> DispatchTimeInterval {
        attempts.removeAll { $0 + .seconds(30) <= now }
        let excess = attempts.count - 2
        let milliseconds = excess > 0 ? min(500 << min(excess - 1, 4), 8_000) : 0
        attempts.append(now + .milliseconds(milliseconds))
        return .milliseconds(milliseconds)
    }
}

/// Whether the app is in the background, as outputs need it: there the system takes decoders and display resources
/// away. Failures there, and right after coming back, say nothing about
/// the media.
final class ApplicationActivity: @unchecked Sendable {
    static let shared = ApplicationActivity()

    var isInBackground: Bool {
        lock.withLock { _isInBackground }
    }

    private let lock = UnfairLock()
    private var _isInBackground = false
    private var enteredForegroundAt: DispatchTime?
    private var observers: [NSObjectProtocol] = []
    /// Called, on no particular thread, once the app is in the foreground again.
    private var foregroundActions: [@Sendable () -> Void] = []

    private init() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.setInBackground(true)
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.setInBackground(false)
        })
        #endif
    }

    /// Whether the app is in the background, or came back less than `interval` ago.
    func isAwayOrReturning(within interval: DispatchTimeInterval = .seconds(2)) -> Bool {
        lock.withLock {
            guard !_isInBackground else { return true }
            return enteredForegroundAt.map { $0 + interval > .now() } ?? false
        }
    }

    /// Calls `action` once the app is in the foreground: now if it is, otherwise when it enters it, on no particular
    /// thread.
    func whenInForeground(_ action: @escaping @Sendable () -> Void) {
        let runsNow = lock.withLock {
            if _isInBackground { foregroundActions.append(action) }
            return !_isInBackground
        }
        if runsNow { action() }
    }

    private func setInBackground(_ isInBackground: Bool) {
        let actions = lock.withLock { () -> [@Sendable () -> Void] in
            _isInBackground = isInBackground
            enteredForegroundAt = isInBackground ? nil : .now()
            guard !isInBackground else { return [] }
            defer { foregroundActions.removeAll() }
            return foregroundActions
        }
        SELogger.debug(.recovery, isInBackground ? "The app entered the background" : "The app enters the foreground")
        actions.forEach { $0() }
    }
}

public extension SERenderer {
    func getRecoveryContext() -> RendererRecoveryContext { .init(generation: 0, mediaPeriodId: nil) }
    var isRecoveringWhileTimelineAdvances: Bool { false }
    func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool { false }
}

public extension SERendererDelegate {
    func rendererNeedsRecovery(_ renderer: SERenderer, request: RendererRecoveryRequest) {}
}
