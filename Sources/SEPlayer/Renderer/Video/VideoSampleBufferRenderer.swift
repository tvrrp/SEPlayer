//
//  VideoSampleBufferRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.12.2025.
//

import AVFoundation
import SEPlayerCommon

public protocol VideoSampleBufferRendererDelegate: AnyObject {
    nonisolated var isolation: any Actor { get }
    func renderer(_ renderer: VideoSampleBufferRenderer, didFailRenderingWith error: Error, isolation: isolated any Actor)
    func renderer(_ renderer: VideoSampleBufferRenderer, didChangeReadyForDisplay: Bool, isolation: isolated any Actor)
}

public protocol VideoSampleBufferRenderer: VideoSampleBufferRendererPerformance, Sendable {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? { get set }
    var isReadyForDisplay: Bool { get }
    var isReadyForMoreMediaData: Bool { get }
    var hasSufficientMediaDataForReliablePlaybackStart: Bool { get }
    var requiresFlushToResumeDecoding: Bool { get }
    /// Whether the renderer failed, and takes nothing until a flush.
    var hasFailed: Bool { get }

    /// Joins the synchronizer, or follows the timebase; `nil` detaches it from both.
    func setTimeSource(_ source: RendererTimeSource?)
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func flush(removeImage: Bool)
    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async
    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
}

/// A promise about the presentation times of the samples enqueued from now on, for forward playback.
///
/// With a lower bound the layer knows no new frame can be due before it, so the display stops checking for new
/// frames until then and wakes only for the frames already queued. A sample enqueued later with a lower time may
/// be dropped. A flush ends the promise.
public enum PresentationTimeExpectation {
    case none
    /// Every sample has a later time than all samples before it. Not true of samples in decode order.
    case monotonicallyIncreasing
    /// No sample has a time lower than this one.
    case minimumUpcoming(CMTime)
}

public protocol VideoSampleBufferRendererPerformance: AnyObject {
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation)
}

extension AVSampleBufferDisplayLayer {
    private static let expectMinimumSelector = NSSelectorFromString("expectMinimumUpcomingSampleBufferPresentationTime:")
    private static let expectMonotonicSelector = NSSelectorFromString("expectMonotonicallyIncreasingUpcomingSampleBufferPresentationTimes")
    private static let resetExpectationsSelector = NSSelectorFromString("resetUpcomingSampleBufferPresentationTimeExpectations")

    /// The same promise made through the layer, where its own methods exist.
    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        switch expectation {
        case let .minimumUpcoming(time):
            let selector = Self.expectMinimumSelector
            guard responds(to: selector) else { return }
            // The time goes by value: `perform(_:with:)` only passes objects.
            typealias Method = @convention(c) (AnyObject, Selector, CMTime) -> Void
            unsafeBitCast(method(for: selector), to: Method.self)(self, selector, time)
        case .monotonicallyIncreasing:
            if responds(to: Self.expectMonotonicSelector) {
                perform(Self.expectMonotonicSelector)
            }
        case .none:
            if responds(to: Self.resetExpectationsSelector) {
                perform(Self.resetExpectationsSelector)
            }
        }
    }
}

@available(tvOS 17.0, *)
@available(iOS 17.0, *)
final class AVSBVideoRenderer: VideoSampleBufferRenderer {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
    var isReadyForDisplay: Bool {
        if #available(iOS 17.4, macCatalyst 17.4, tvOS 17.4, *) {
            layer.isReadyForDisplay
        } else {
            true
        }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        renderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    var requiresFlushToResumeDecoding: Bool {
        renderer.requiresFlushToResumeDecoding
    }

    var hasFailed: Bool {
        renderer.status == .failed
    }

    private let lock = UnfairLock()
    private nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer
    private let timeSource = TimeSourceAttachment()
    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock

    init(renderer: AVSampleBufferVideoRenderer, layer: AVSampleBufferDisplayLayer) {
        self.renderer = renderer
        self.layer = layer

        observer = renderer.observe(\.status) { [weak self] renderer, _ in
            guard let self else { return }
            if renderer.status == .failed, let error = renderer.error, let delegate {
                Task {
                    await delegate.renderer(self, didFailRenderingWith: error, isolation: delegate.isolation)
                }
            }
        }

        if #available(iOS 17.4, tvOS 17.4, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(readyForDisplayDidChange),
                name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: layer
            )
        }
        // Decoding can stop without the renderer failing: it then waits for a flush, and shows nothing until.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(decodingDidFail(_:)),
            name: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(decodingDidFail(_:)),
            name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer
        )
    }

    deinit {
        observer?.invalidate()
        timeSource.set(nil, layer: layer, renderer: renderer)
    }

    @objc
    private func decodingDidFail(_ notification: Notification) {
        guard renderer.requiresFlushToResumeDecoding, let delegate else {
            return
        }
        let error = notification.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? Error
            ?? renderer.error
            ?? AVError(.decodeFailed)
        Task {
            await delegate.renderer(self, didFailRenderingWith: error, isolation: delegate.isolation)
        }
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            switch expectation {
            case .none:
                renderer.presentationTimeExpectation = .none
            case .monotonicallyIncreasing:
                renderer.presentationTimeExpectation = .monotonicallyIncreasing
            case let .minimumUpcoming(time):
                renderer.presentationTimeExpectation = .minimumUpcoming(time)
            }
        } else {
            layer.setPresentationTimeExpectation(expectation)
        }
    }

    func setTimeSource(_ source: RendererTimeSource?) {
        timeSource.set(source, layer: layer, renderer: renderer)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func flush() {
        renderer.flush()
    }

    func flush(removeImage: Bool) {
        renderer.flush(removingDisplayedImage: removeImage)
    }

    func flushAsync(removeImage: Bool) async {
        await renderer.flush(removingDisplayedImage: removeImage)
    }

    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        renderer.flush(removingDisplayedImage: removeImage, completionHandler: completion)
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    @objc
    private func readyForDisplayDidChange() {
        if #available(iOS 17.4, tvOS 17.4, *) {
            Task {
                guard let delegate else { return }
                await delegate.renderer(self, didChangeReadyForDisplay: layer.isReadyForDisplay, isolation: delegate.isolation)
            }
        }
    }
}

final class AVSBDLVideoRenderer: VideoSampleBufferRenderer {
    nonisolated var delegate: VideoSampleBufferRendererDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    var isReadyForMoreMediaData: Bool {
        layer.isReadyForMoreMediaData
    }

    var isReadyForDisplay: Bool {
        if #available(iOS 17.4, tvOS 17.4, macCatalyst 17.4, *) {
            layer.isReadyForDisplay
        } else {
            true
        }
    }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        layer.hasSufficientMediaDataForReliablePlaybackStart
    }

    var requiresFlushToResumeDecoding: Bool {
        layer.requiresFlushToResumeDecoding
    }

    var hasFailed: Bool {
        layer.status == .failed
    }

    private nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private let lock = UnfairLock()
    private let timeSource = TimeSourceAttachment()

    private nonisolated(unsafe) var observer: NSKeyValueObservation? // mutated only on init
    private nonisolated(unsafe) weak var _delegate: VideoSampleBufferRendererDelegate? // guarded by lock

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer

        observer = layer.observe(\.status) { [weak self] layer, _ in
            guard let self else { return }
            if layer.status == .failed, let error = layer.error, let delegate {
                Task {
                    await delegate.renderer(self, didFailRenderingWith: error, isolation: delegate.isolation)
                }
            }
        }

        if #available(iOS 17.4, tvOS 17.4, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(readyForDisplayDidChange),
                name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                object: layer
            )
        }
        // Decoding can stop without the layer failing: it then waits for a flush, and shows nothing until.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(decodingDidFail(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: layer
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(decodingDidFail(_:)),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
            object: layer
        )
    }

    deinit {
        observer?.invalidate()
        timeSource.set(nil, layer: layer, renderer: layer)
    }

    @objc
    private func decodingDidFail(_ notification: Notification) {
        guard layer.requiresFlushToResumeDecoding, let delegate else { return }
        let error = notification.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error
            ?? layer.error
            ?? AVError(.decodeFailed)
        Task {
            await delegate.renderer(self, didFailRenderingWith: error, isolation: delegate.isolation)
        }
    }

    func setPresentationTimeExpectation(_ expectation: PresentationTimeExpectation) {
        layer.setPresentationTimeExpectation(expectation)
    }

    func setTimeSource(_ source: RendererTimeSource?) {
        timeSource.set(source, layer: layer, renderer: layer)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        layer.enqueue(sampleBuffer)
    }

    func flush() {
        layer.flush()
    }

    func flush(removeImage: Bool) {
        if removeImage {
            layer.flushAndRemoveImage()
        } else {
            layer.flush()
        }
    }

    @available(iOS 17.0, *)
    func flushAsync(removeImage: Bool) async {
        if removeImage {
            await layer.flushAndRemoveImage()
        } else {
            await layer.flush()
        }
    }

    @available(iOS 17.0, *)
    func flush(removeImage: Bool, completion: @escaping () -> Void) {
        if removeImage {
            self.layer.flushAndRemoveImage()
        } else {
            self.layer.flush()
        }
    }

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {
        layer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        layer.stopRequestingMediaData()
    }

    @objc
    private func readyForDisplayDidChange() {
        if #available(iOS 17.4, tvOS 17.4, *) {
            Task {
                guard let delegate else { return }
                await delegate.renderer(self, didChangeReadyForDisplay: layer.isReadyForDisplay, isolation: delegate.isolation)
            }
        }
    }
}

/// Which synchronizer a layer has joined. A renderer in a synchronizer must not get a control timebase, and it is
/// only out of the synchronizer once `removeRenderer` completes, even at an invalid time; until then a new source
/// waits.
private final class TimeSourceAttachment: @unchecked Sendable {
    private let lock = UnfairLock()
    // All guarded by lock.
    private var joined: AVSampleBufferRenderSynchronizer?
    private var desired: RendererTimeSource?
    private var isLeaving = false

    func set(
        _ source: RendererTimeSource?,
        layer: AVSampleBufferDisplayLayer,
        renderer: any AVQueuedSampleBufferRendering
    ) {
        let leaving: AVSampleBufferRenderSynchronizer? = lock.withLock {
            desired = source
            // A layer still leaving takes the source once it has left.
            guard !isLeaving, let joined, joined !== source?.synchronizer else {
                return nil
            }
            isLeaving = true
            self.joined = nil
            return joined
        }

        guard let leaving else {
            applyDesired(layer: layer, renderer: renderer)
            return
        }
        SELogger.debug(.sync, "layer: leaving synchronizer (rate \(leaving.rate), time \(leaving.timebase.time.seconds))")
        // Outside the lock: the completion may run at once.
        leaving.removeRenderer(renderer, at: .invalid) { [weak self] result in
            SELogger.debug(.sync, "layer: left synchronizer, removed \(result)")
            guard let self else { return }
            lock.withLock { self.isLeaving = false }
            applyDesired(layer: layer, renderer: renderer)
        }
    }

    private func applyDesired(layer: AVSampleBufferDisplayLayer, renderer: any AVQueuedSampleBufferRendering) {
        lock.withLock {
            guard !isLeaving else { return }
            // A synchronizer of another kind can't take the layer: it follows its timebase.
            let desired: RendererTimeSource? = switch self.desired {
            case let .synchronizer(synchronizer) where !(synchronizer is AVSampleBufferRenderSynchronizer):
                .timebase(synchronizer.timebase)
            default:
                self.desired
            }
            switch desired {
            case let .timebase(timebase):
                guard joined == nil else { return }
                if layer.controlTimebase !== timebase {
                    SELogger.debug(.sync, "layer: follows timebase at \(timebase.time.seconds) rate \(timebase.rate)")
                    layer.controlTimebase = timebase
                }
            case let .synchronizer(source):
                guard joined == nil, let synchronizer = source as? AVSampleBufferRenderSynchronizer else {
                    return
                }
                SELogger.debug(.sync, "layer: joins synchronizer (rate \(synchronizer.rate), time \(synchronizer.timebase.time.seconds))")
                if layer.controlTimebase != nil { layer.controlTimebase = nil }
                synchronizer.addRenderer(renderer)
                joined = synchronizer
            case nil:
                if joined == nil, layer.controlTimebase != nil {
                    layer.controlTimebase = nil
                }
            }
        }
    }
}
