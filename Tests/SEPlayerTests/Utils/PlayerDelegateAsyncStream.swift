//
//  PlayerDelegateAsyncStream.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Testing
import Foundation
@testable import SEPlayer

final class PlayerDelegateAsyncStream {
    private var continuation: AsyncStream<Event>.Continuation?

    @MainActor
    init(delegate: MulticastDelegate<SEPlayerDelegate>) {
        delegate.addDelegate(self)
    }
 
    func start() -> AsyncStream<Event> {
        return AsyncStream<Event> { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
                self?.continuation = nil
            }
        }
    }
}

final class CollectablePlayerDelegateAsyncStream {
    var events = [PlayerDelegateAsyncStream.Event]()

    final class EventValidator {
        let validation: ((PlayerDelegateAsyncStream.Event) -> Bool)
        var continuation: CheckedContinuation<Void, Never>?

        init(validation: @escaping (PlayerDelegateAsyncStream.Event) -> Bool) {
            self.validation = validation
        }
    }

    private let playerDelegateAsyncStream: PlayerDelegateAsyncStream
    private let eventValidator: EventValidator?

    @MainActor
    init(
        delegate: MulticastDelegate<SEPlayerDelegate>,
        eventValidator: EventValidator
    ) {
        playerDelegateAsyncStream = .init(delegate: delegate)
        self.eventValidator = eventValidator
    }

    func startCollecting(isolation: isolated (any Actor)? = #isolation) {
        Task { [self] in
            for await event in playerDelegateAsyncStream.start() {
                print("❌ EVENT = \(event)")
                events.append(event)

                if eventValidator?.validation(event) == true {
                    eventValidator?.continuation?.resume()
                    break
                }
            }
        }
    }
}

extension PlayerDelegateAsyncStream: SEPlayerDelegate {
    enum Event {
        case didChangeTimeline(timeline: Timeline, reason: TimelineChangeReason)
        case didTransitionMediaItem(mediaItem: MediaItem?, reason: MediaItemTransitionReason?)
        case didChangeIsLoading(isLoading: Bool)
        case didChangePlaybackState(state: PlayerState)
        case didChangePlayWhenReady(playWhenReady: Bool, reason: PlayWhenReadyChangeReason)
        case didChangePlaybackSuppressionReason(reason: PlaybackSuppressionReason)
        case didChangeIsPlaying(isPlaying: Bool)
        case didChangeRepeatMode(repeatMode: RepeatMode)
        case didChangeShuffleMode(shuffleModeEnabled: Bool)
        case onPlayerError(error: Error)
        case didChangePlayerError(error: Error?)
        case didChangePositionDiscontinuity(oldPosition: PositionInfo, newPosition: PositionInfo, reason: DiscontinuityReason)
        case didChangePlaybackParameters(playbackParameters: PlaybackParameters)
        case didChangeSeekBackIncrement(seekBackIncrementMs: Int64)
        case didChangeSeekForwardIncrement(seekForwardIncrementMs: Int64)
        case didChangeMaxSeekToPreviousPosition(maxSeekToPreviousPositionMs: Int64)
    }

    func player(_ player: Player, didChangeTimeline timeline: Timeline, reason: TimelineChangeReason) {
        continuation?.yield(.didChangeTimeline(timeline: timeline, reason: reason))
    }

    func player(_ player: Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        continuation?.yield(.didTransitionMediaItem(mediaItem: mediaItem, reason: reason))
    }

    func player(_ player: Player, didChangeIsLoading isLoading: Bool) {
        continuation?.yield(.didChangeIsLoading(isLoading: isLoading))
    }

    func player(_ player: Player, didChangePlaybackState state: PlayerState) {
        continuation?.yield(.didChangePlaybackState(state: state))
    }

    func player(_ player: Player, didChangePlayWhenReady playWhenReady: Bool, reason: PlayWhenReadyChangeReason) {
        continuation?.yield(.didChangePlayWhenReady(playWhenReady: playWhenReady, reason: reason))
    }

    func player(_ player: Player, didChangePlaybackSuppressionReason reason: PlaybackSuppressionReason) {
        continuation?.yield(.didChangePlaybackSuppressionReason(reason: reason))
    }

    func player(_ player: Player, didChangeIsPlaying isPlaying: Bool) {
        continuation?.yield(.didChangeIsPlaying(isPlaying: isPlaying))
    }

    func player(_ player: Player, didChangeRepeatMode repeatMode: RepeatMode) {
        continuation?.yield(.didChangeRepeatMode(repeatMode: repeatMode))
    }

    func player(_ player: Player, didChangeShuffleMode shuffleModeEnabled: Bool) {
        continuation?.yield(.didChangeShuffleMode(shuffleModeEnabled: shuffleModeEnabled))
    }

    func player(_ player: Player, onPlayerError error: Error) {
        continuation?.yield(.onPlayerError(error: error))
    }

    func player(_ player: Player, didChangePlayerError error: Error?) {
        continuation?.yield(.didChangePlayerError(error: error))
    }

    func player(
        _ player: Player,
        didChangePositionDiscontinuity oldPosition: PositionInfo,
        newPosition: PositionInfo,
        reason: DiscontinuityReason
    ) {
        continuation?.yield(.didChangePositionDiscontinuity(oldPosition: oldPosition, newPosition: newPosition, reason: reason))
    }

    func player(_ player: Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {
        continuation?.yield(.didChangePlaybackParameters(playbackParameters: playbackParameters))
    }

    func player(_ player: Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64) {
        continuation?.yield(.didChangeSeekBackIncrement(seekBackIncrementMs: seekBackIncrementMs))
    }

    func player(_ player: Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64) {
        continuation?.yield(.didChangeSeekForwardIncrement(seekForwardIncrementMs: seekForwardIncrementMs))
    }

    func player(_ player: Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64) {
        continuation?.yield(.didChangeMaxSeekToPreviousPosition(maxSeekToPreviousPositionMs: maxSeekToPreviousPositionMs))
    }
}
