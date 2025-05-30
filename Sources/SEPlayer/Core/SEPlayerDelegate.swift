//
//  SEPlayerDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@MainActor public protocol SEPlayerDelegate: AnyObject {
    func player(_ player: SEPlayer.Player, didChangeTimeline timeline: Timeline, reason: SEPlayer.TimelineChangeReason)
    func player(_ player: SEPlayer.Player, didTransitionMediaItem mediaItem: MediaItem?, reason: SEPlayer.MediaItemTransitionReason?)
    func player(_ player: SEPlayer.Player, didChangeIsLoading isLoading: Bool)
    func player(_ player: SEPlayer.Player, didChangePlaybackState state: SEPlayer.State)
    func player(_ player: SEPlayer.Player, didChangePlayWhenReady playWhenReady: Bool, reason: SEPlayer.PlayWhenReadyChangeReason)
    func player(_ player: SEPlayer.Player, didChangePlaybackSuppressionReason reason: SEPlayer.PlaybackSuppressionReason)
    func player(_ player: SEPlayer.Player, didChangeIsPlaying isPlaying: Bool)
    func player(_ player: SEPlayer.Player, didChangeRepeatMode repeatMode: SEPlayer.RepeatMode)
    func player(_ player: SEPlayer.Player, didChangeShuffleMode shuffleModeEnabled: Bool)
    func player(_ player: SEPlayer.Player, onPlayerError error: Error)
    func player(_ player: SEPlayer.Player, didChangePlayerError error: Error?)
    func player(
        _ player: SEPlayer.Player,
        didChangePositionDiscontinuity oldPosition: SEPlayer.PositionInfo,
        newPosition: SEPlayer.PositionInfo,
        reason: SEPlayer.DiscontinuityReason
    )
    func player(_ player: SEPlayer.Player, didChangePlaybackParameters playbackParameters: PlaybackParameters)
    func player(_ player: SEPlayer.Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64)
    func player(_ player: SEPlayer.Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64)
    func player(_ player: SEPlayer.Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64)
    
}

public extension SEPlayerDelegate {
    func player(_ player: SEPlayer.Player, didChangeTimeline timeline: Timeline, reason: SEPlayer.TimelineChangeReason) {
        print("🔥 didChangeTimeline")
    }

    func player(_ player: SEPlayer.Player, didTransitionMediaItem mediaItem: MediaItem?, reason: SEPlayer.MediaItemTransitionReason?) {
        print("🔥 didTransitionMediaItem")
    }

    func player(_ player: SEPlayer.Player, didChangeIsLoading isLoading: Bool) {
        print("🔥 didChangeIsLoading")
    }

    func player(_ player: SEPlayer.Player, didChangePlaybackState state: SEPlayer.State) {
        print("🔥 didChangePlaybackState = \(state)")
    }

    func player(_ player: SEPlayer.Player, didChangePlayWhenReady playWhenReady: Bool, reason: SEPlayer.PlayWhenReadyChangeReason) {
        print("🔥 didChangePlayWhenReady")
    }

    func player(_ player: SEPlayer.Player, didChangePlaybackSuppressionReason reason: SEPlayer.PlaybackSuppressionReason) {
        print("🔥 didChangePlaybackSuppressionReason")
    }

    func player(_ player: SEPlayer.Player, didChangeIsPlaying isPlaying: Bool) {
        print("🔥 didChangeIsPlaying")
    }

    func player(_ player: SEPlayer.Player, didChangeRepeatMode repeatMode: SEPlayer.RepeatMode) {
        print("🔥 didChangeRepeatMode")
    }

    func player(_ player: SEPlayer.Player, didChangeShuffleMode shuffleModeEnabled: Bool) {
        print("🔥 didChangeShuffleMode")
    }

    func player(_ player: SEPlayer.Player, onPlayerError error: Error) {
        print("🔥 onPlayerError")
    }

    func player(_ player: SEPlayer.Player, didChangePlayerError error: Error?) {
        print("🔥 didChangePlayerError")
    }

    func player(
        _ player: SEPlayer.Player,
        didChangePositionDiscontinuity oldPosition: SEPlayer.PositionInfo,
        newPosition: SEPlayer.PositionInfo,
        reason: SEPlayer.DiscontinuityReason
    ) {
        print("🔥 didChangePositionDiscontinuity")
    }
    func player(_ player: SEPlayer.Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {}
    func player(_ player: SEPlayer.Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64) {}
    func player(_ player: SEPlayer.Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64) {}
    func player(_ player: SEPlayer.Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64) {}
}
