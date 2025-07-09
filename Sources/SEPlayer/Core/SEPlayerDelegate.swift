//
//  SEPlayerDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@MainActor public protocol SEPlayerDelegate: AnyObject {
    func player(_ player: Player, didChangeTimeline timeline: Timeline, reason: TimelineChangeReason)
    func player(_ player: Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?)
    func player(_ player: Player, didChangeIsLoading isLoading: Bool)
    func player(_ player: Player, didChangePlaybackState state: PlayerState)
    func player(_ player: Player, didChangePlayWhenReady playWhenReady: Bool, reason: PlayWhenReadyChangeReason)
    func player(_ player: Player, didChangePlaybackSuppressionReason reason: PlaybackSuppressionReason)
    func player(_ player: Player, didChangeIsPlaying isPlaying: Bool)
    func player(_ player: Player, didChangeRepeatMode repeatMode: RepeatMode)
    func player(_ player: Player, didChangeShuffleMode shuffleModeEnabled: Bool)
    func player(_ player: Player, onPlayerError error: Error)
    func player(_ player: Player, didChangePlayerError error: Error?)
    func player(
        _ player: Player,
        didChangePositionDiscontinuity oldPosition: PositionInfo,
        newPosition: PositionInfo,
        reason: DiscontinuityReason
    )
    func player(_ player: Player, didChangePlaybackParameters playbackParameters: PlaybackParameters)
    func player(_ player: Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64)
    func player(_ player: Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64)
    func player(_ player: Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64)
}

public extension SEPlayerDelegate {
    func player(_ player: Player, didChangeTimeline timeline: Timeline, reason: TimelineChangeReason) {
        print("🔥 didChangeTimeline")
    }

    func player(_ player: Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        print("🔥 didTransitionMediaItem")
    }

    func player(_ player: Player, didChangeIsLoading isLoading: Bool) {
        print("🔥 didChangeIsLoading")
    }

    func player(_ player: Player, didChangePlaybackState state: PlayerState) {
        print("🔥 didChangePlaybackState = \(state)")
    }

    func player(_ player: Player, didChangePlayWhenReady playWhenReady: Bool, reason: PlayWhenReadyChangeReason) {
        print("🔥 didChangePlayWhenReady")
    }

    func player(_ player: Player, didChangePlaybackSuppressionReason reason: PlaybackSuppressionReason) {
        print("🔥 didChangePlaybackSuppressionReason")
    }

    func player(_ player: Player, didChangeIsPlaying isPlaying: Bool) {
        print("🔥 didChangeIsPlaying")
    }

    func player(_ player: Player, didChangeRepeatMode repeatMode: RepeatMode) {
        print("🔥 didChangeRepeatMode")
    }

    func player(_ player: Player, didChangeShuffleMode shuffleModeEnabled: Bool) {}
    func player(_ player: Player, onPlayerError error: Error) {}
    func player(_ player: Player, didChangePlayerError error: Error?) {}

    func player(
        _ player: Player,
        didChangePositionDiscontinuity oldPosition: PositionInfo,
        newPosition: PositionInfo,
        reason: DiscontinuityReason
    ) {
        print("🔥 didChangePositionDiscontinuity")
    }
    func player(_ player: Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {}
    func player(_ player: Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64) {}
    func player(_ player: Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64) {}
    func player(_ player: Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64) {}
}
