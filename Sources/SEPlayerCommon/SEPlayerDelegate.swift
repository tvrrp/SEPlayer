//
//  SEPlayerDelegate.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@MainActor
public protocol SEPlayerDelegate: AnyObject {
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
    /// Called when there is a change in the `CueGroup`.
    func player(_ player: Player, didChangeCues cueGroup: CueGroup)
    /// Called when ``Player/currentTracks`` changes.
    ///
    /// - Parameter tracks: The tracks of the current media item. May have no groups.
    func player(_ player: Player, didChangeTracks tracks: Tracks)
    /// Called when ``Player/trackSelectionParameters`` changes.
    func player(_ player: Player, didChangeTrackSelectionParameters parameters: TrackSelectionParameters)
    /// Called when ``Player/mediaMetadata`` changes.
    func player(_ player: Player, didChangeMediaMetadata mediaMetadata: MediaMetadata)
    /// Called when ``Player/playlistMetadata`` changes.
    func player(_ player: Player, didChangePlaylistMetadata playlistMetadata: MediaMetadata)
    /// Called when ``Player/volume`` changes.
    func player(_ player: Player, didChangeVolume volume: Float)
    /// Called when ``Player/isMuted`` changes.
    func player(_ player: Player, didChangeIsMuted isMuted: Bool)
    /// Called when ``Player/videoSize`` changes: when the first frame of a different size is about to show.
    func player(_ player: Player, didChangeVideoSize videoSize: VideoSize)
    /// Called when a frame shows for the first time since the video started, or since a seek.
    func playerDidRenderFirstFrame(_ player: Player)
}

public extension SEPlayerDelegate {
    func player(_ player: Player, didChangeTimeline timeline: Timeline, reason: TimelineChangeReason) {}

    func player(_ player: Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {}

    func player(_ player: Player, didChangeIsLoading isLoading: Bool) {}

    func player(_ player: Player, didChangePlaybackState state: PlayerState) {}

    func player(_ player: Player, didChangePlayWhenReady playWhenReady: Bool, reason: PlayWhenReadyChangeReason) {}

    func player(_ player: Player, didChangePlaybackSuppressionReason reason: PlaybackSuppressionReason) {}

    func player(_ player: Player, didChangeIsPlaying isPlaying: Bool) {}

    func player(_ player: Player, didChangeRepeatMode repeatMode: RepeatMode) {}

    func player(_ player: Player, didChangeShuffleMode shuffleModeEnabled: Bool) {}
    func player(_ player: Player, onPlayerError error: Error) {}
    func player(_ player: Player, didChangePlayerError error: Error?) {}

    func player(
        _ player: Player,
        didChangePositionDiscontinuity oldPosition: PositionInfo,
        newPosition: PositionInfo,
        reason: DiscontinuityReason
    ) {}
    func player(_ player: Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {}
    func player(_ player: Player, didChangeSeekBackIncrement seekBackIncrementMs: Int64) {}
    func player(_ player: Player, didChangeSeekForwardIncrement seekForwardIncrementMs: Int64) {}
    func player(_ player: Player, didChangeMaxSeekToPreviousPosition maxSeekToPreviousPositionMs: Int64) {}
    func player(_ player: Player, didChangeCues cueGroup: CueGroup) {}
    func player(_ player: Player, didChangeTracks tracks: Tracks) {}
    func player(_ player: Player, didChangeTrackSelectionParameters parameters: TrackSelectionParameters) {}
    func player(_ player: Player, didChangeMediaMetadata mediaMetadata: MediaMetadata) {}
    func player(_ player: Player, didChangePlaylistMetadata playlistMetadata: MediaMetadata) {}
    func player(_ player: Player, didChangeVolume volume: Float) {}
    func player(_ player: Player, didChangeIsMuted isMuted: Bool) {}
    func player(_ player: Player, didChangeVideoSize videoSize: VideoSize) {}
    func playerDidRenderFirstFrame(_ player: Player) {}
}
