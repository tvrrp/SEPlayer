//
//  SEPlaybackError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import AVFoundation
import DataSource
import SEPlayerCommon
import VideoToolbox

/// The error playback stopped with.
///
/// ``type`` tells where it happened, ``errorCode`` what failed. Errors of the source stop playback with the renderers
/// kept; errors of a renderer, and unexpected ones, reset the renderers too.
public struct SEPlaybackError: Error, PlaybackErrorCodeProviding {
    public let type: ErrorSource
    /// What failed.
    public let errorCode: PlaybackErrorCode
    /// The period that was playing, or for a renderer error the one the renderer read.
    public let mediaPeriodId: MediaPeriodId
    public let isRecoverable: Bool
    public let underlyingError: Error?
    /// If a recovery attempt itself failed, this preserves its failure separately from the original output error.
    public let recoveryError: Error?

    public init(
        type: ErrorSource,
        errorCode: PlaybackErrorCode? = nil,
        mediaPeriodId: MediaPeriodId,
        isRecoverable: Bool,
        underlyingError: Error? = nil,
        recoveryError: Error? = nil
    ) {
        self.type = type
        self.errorCode = errorCode ?? Self.errorCode(for: underlyingError, type: type)
        self.mediaPeriodId = mediaPeriodId
        self.isRecoverable = isRecoverable
        self.underlyingError = underlyingError
        self.recoveryError = recoveryError
    }

    /// The error of the source: loading or parsing the media failed.
    public static func createForSource(_ error: Error, mediaPeriodId: MediaPeriodId = .init()) -> SEPlaybackError {
        SEPlaybackError(type: .mediaSource, mediaPeriodId: mediaPeriodId, isRecoverable: false, underlyingError: error)
    }

    /// The error of the player itself: a bug, or a state it can't go on from.
    public static func createForUnexpected(
        _ error: Error,
        errorCode: PlaybackErrorCode? = nil,
        mediaPeriodId: MediaPeriodId = .init()
    ) -> SEPlaybackError {
        SEPlaybackError(
            type: .unexpected,
            errorCode: errorCode,
            mediaPeriodId: mediaPeriodId,
            isRecoverable: false,
            underlyingError: error
        )
    }

    /// The error of a renderer: decoding or output of its track failed.
    public static func createForRenderer(
        _ error: Error,
        rendererName: String,
        rendererIndex: Int,
        trackType: TrackType,
        format: AnyFormat?,
        mediaPeriodId: MediaPeriodId,
        isRecoverable: Bool = false
    ) -> SEPlaybackError {
        SEPlaybackError(
            type: .renderer(.error(.init(
                rendererName: rendererName,
                rendererIndex: rendererIndex,
                rendererFormat: format,
                rendererFormatSupport: nil
            ))),
            errorCode: rendererErrorCode(for: error, trackType: trackType),
            mediaPeriodId: mediaPeriodId,
            isRecoverable: isRecoverable,
            underlyingError: error
        )
    }

    /// The playback error of any error: an ``SEPlaybackError`` stays as it is, one of loading or parsing is an error
    /// of the source, and anything else is unexpected.
    public static func create(from error: Error) -> SEPlaybackError {
        if let error = error as? SEPlaybackError { return error }
        if isSourceError(error) { return createForSource(error) }
        return createForUnexpected(error)
    }

    /// The same error, for another period.
    public func copy(with mediaPeriodId: MediaPeriodId) -> SEPlaybackError {
        SEPlaybackError(
            type: type,
            errorCode: errorCode,
            mediaPeriodId: mediaPeriodId,
            isRecoverable: isRecoverable,
            underlyingError: underlyingError,
            recoveryError: recoveryError
        )
    }
}

public extension SEPlaybackError {
    enum ErrorSource {
        case mediaSource
        case renderer(RendererErrorType)
        case unexpected
        case remote
    }

    enum RendererErrorType {
        case rendererRequiresFlush
        case error(RendererError)
    }

    struct RendererError: Error {
        public let rendererName: String
        public let rendererIndex: Int
        public let rendererFormat: AnyFormat?
        public let rendererFormatSupport: RendererCapabilities.Support.FormatSupport?
    }
}

extension SEPlaybackError: CustomStringConvertible {
    public var description: String {
        var description = "SEPlaybackError(\(errorCode), \(type)"
        if let underlyingError { description += ", underlying: \(underlyingError)" }
        if let recoveryError { description += ", recovery: \(recoveryError)" }
        return description + ")"
    }
}

/// Thrown when playback stays buffering with an almost empty buffer while nothing loads.
public struct PlaybackStuckError: PlaybackErrorCodeProviding {
    public var errorCode: PlaybackErrorCode { .timeout }
}

// MARK: - Error codes

private extension SEPlaybackError {
    static func errorCode(for error: Error?, type: ErrorSource) -> PlaybackErrorCode {
        guard let error else { return .unspecified }
        switch type {
        case .mediaSource:
            return sourceErrorCode(for: error) ?? .ioUnspecified
        case .renderer:
            return rendererErrorCode(for: error, trackType: .unknown)
        case .unexpected,
             .remote:
            if let error = error as? PlaybackErrorCodeProviding { return error.errorCode }
            return error is UnexpectedStateError || error is UnsupportedOperationError ? .failedRuntimeCheck : .unspecified
        }
    }

    /// Whether the error is one of loading or parsing the media.
    static func isSourceError(_ error: Error) -> Bool {
        if let code = sourceErrorCode(for: error) {
            return code == .behindLiveWindow || (2000 ..< 4000).contains(code.rawValue)
        }
        return false
    }

    static func sourceErrorCode(for error: Error) -> PlaybackErrorCode? {
        if let error = error as? PlaybackErrorCodeProviding { return error.errorCode }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLSessionDataSourceError(error: nsError).errorCode
        }
        return nil
    }

    static func rendererErrorCode(for error: Error, trackType: TrackType) -> PlaybackErrorCode {
        if let error = error as? SEPlaybackError { return error.errorCode }
        if let error = error as? PlaybackErrorCodeProviding { return error.errorCode }
        if let error = error as? RendererRecoveryError {
            switch error {
            case .unsupportedAudioDecoding: return .decodingFormatUnsupported
            case .timedOut: return .timeout
            case .positionUnavailable: break
            }
        }

        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: nsError.code) {
            case .decoderNotFound?: return .decodingFormatUnsupported
            case .decoderTemporarilyUnavailable?: return .decoderInitFailed
            case .decodeFailed?: return .decodingFailed
            default: break
            }
        }
        if nsError.domain == NSOSStatusErrorDomain {
            switch OSStatus(nsError.code) {
            case kVTCouldNotFindVideoDecoderErr,
                 kVTVideoDecoderUnsupportedDataFormatErr: return .decodingFormatUnsupported
            case kVTVideoDecoderNotAvailableNowErr,
                 kVTVideoDecoderAuthorizationErr: return .decoderInitFailed
            case kVTVideoDecoderBadDataErr,
                 kVTVideoDecoderMalfunctionErr: return .decodingFailed
            default: break
            }
        }

        switch trackType {
        case .audio: return .audioOutputWriteFailed
        case .video: return .decodingFailed
        default: return .unspecified
        }
    }
}
