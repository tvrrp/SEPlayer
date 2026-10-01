//
//  SEPlayerMessageImpl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2025.
//

import CoreMedia
import SEPlayerCommon

enum SEPlayerMessageImpl: MessageKind {
    case noMessage
    case playWhenReady(
        _ playWhenReady: Bool,
        _ playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        _ playbackSuppressionReason: PlaybackSuppressionReason
    )
    case doSomeWork
    case maybeUpdatePeriods
    case seekTo(
        _ timeline: Timeline,
        _ windowIndex: Int,
        _ position: CMTime,
        _ seekParameters: SeekParameters,
        _ completion: ((Bool) -> Void)?
    )
    case setPlaybackParameters(_ playbackParameters: PlaybackParameters)
    case setVideoOutput(_ output: any VideoOutput)
    case removeVideoOutput(_ output: any VideoOutput)
    case stop
    case release(_ continuation: CheckedContinuation<Void, Never>)
    case periodPrepared(_ mediaPeriod: any MediaPeriod)
//    case sourceAboveHighWaterMark(_ mediaPeriod: any MediaPeriod)
//    case sourceBelowLowWaterMark(_ mediaPeriod: any MediaPeriod)
    case sourceContinueLoadingRequested(_ source: any MediaPeriod)
    case trackSelectionInvalidated
    case setRepeatMode(_ repeatMode: RepeatMode)
    case setShuffleEnabled(_ shuffleModeEnabled: Bool)
    case sendMessage(_ message: PlayerMessage)
    case sendMessageToTargetQueue(_ Message: PlayerMessage)
    case playbackParametersChangedInternal(_ playbackParameters: PlaybackParameters)
    case setMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        _ windowIndex: Int?,
        _ position: CMTime,
        _ shuffleOrder: ShuffleOrder
    )
    case addMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        _ index: Int,
        _ shuffleOrder: ShuffleOrder
    )
    case moveMediaSources(_ range: Range<Int>, _ newIndex: Int, _ shuffleOrder: ShuffleOrder)
    case removeMediaSources(_ range: Range<Int>, _ shuffleOrder: ShuffleOrder)
    case setShuffleOrder(_ shuffleOrder: ShuffleOrder)
    case playlistUpdateRequested
    case setPauseAtEndOfWindow(_ pauseAtEndOfWindow: Bool)
    case errorDelivery(Error)
    case attemptRendererErrorRecovery(_ rendererRequiresFlush: Bool)
    case rendererCapabilitiesChanged
    case updateMediaSourcesWithMediaItems(_ mediaItems: [MediaItem], _ range: Range<Int>)
    case setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration)
    case prepare
}

extension SEPlayerMessageImpl: Equatable {
    func isEqual(to other: MessageKind) -> Bool {
        guard let other = other as? SEPlayerMessageImpl else {
            return false
        }

        return self == other
    }

    static func == (lhs: SEPlayerMessageImpl, rhs: SEPlayerMessageImpl) -> Bool {
        switch (lhs, rhs) {
        case (.noMessage, .noMessage),
             (.playWhenReady, .playWhenReady),
             (.doSomeWork, .doSomeWork),
             (.seekTo, .seekTo),
             (.setPlaybackParameters, .setPlaybackParameters),
             (.stop, .stop),
             (.release, .release),
             (.periodPrepared, .periodPrepared),
             (.sourceContinueLoadingRequested, .sourceContinueLoadingRequested),
             (.trackSelectionInvalidated, .trackSelectionInvalidated),
             (.setRepeatMode, .setRepeatMode),
             (.setShuffleEnabled, .setShuffleEnabled),
             (.sendMessage, .sendMessage),
             (.sendMessageToTargetQueue, .sendMessageToTargetQueue),
             (.playbackParametersChangedInternal, .playbackParametersChangedInternal),
             (.setMediaSources, .setMediaSources),
             (.addMediaSources, .addMediaSources),
             (.moveMediaSources, .moveMediaSources),
             (.removeMediaSources, .removeMediaSources),
             (.setShuffleOrder, .setShuffleOrder),
             (.playlistUpdateRequested, .playlistUpdateRequested),
             (.setPauseAtEndOfWindow, .setPauseAtEndOfWindow),
             (.attemptRendererErrorRecovery, .attemptRendererErrorRecovery),
             (.rendererCapabilitiesChanged, .rendererCapabilitiesChanged),
             (.updateMediaSourcesWithMediaItems, .updateMediaSourcesWithMediaItems),
             (.setPreloadConfiguration, .setPreloadConfiguration),
             (.prepare, .prepare):
            return true
        default:
            return false
        }
    }
}
