//
//  PlayerSnapshot.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.10.2026.
//

import CoreMedia

/// The state of a player at one moment.
///
/// A player can be used from any thread, and the playback queue updates it meanwhile: values read one at a time may
/// come from different moments, as an item index from before a change of timeline and the timeline from after it. The
/// values of a snapshot are read together, with no update between them.
public struct PlayerSnapshot: @unchecked Sendable {
    public let playbackState: PlayerState
    public let playWhenReady: Bool
    public let isPlaying: Bool
    public let isLoading: Bool
    public let playbackParameters: PlaybackParameters

    public let timeline: Timeline
    public let currentMediaItemIndex: Int
    public let currentPeriodIndex: Int?
    public let currentMediaItem: MediaItem?
    public let hasPreviousMediaItem: Bool
    public let hasNextMediaItem: Bool
    public let isCurrentMediaItemSeekable: Bool
    public let isCurrentMediaItemDynamic: Bool

    public let duration: CMTime
    public let currentPosition: CMTime
    public let contentPosition: CMTime
    public let bufferedPosition: CMTime
    public let contentBufferedPosition: CMTime
    public let totalBufferedDuration: CMTime

    public let mediaMetadata: MediaMetadata
    public let videoSize: VideoSize
    public let volume: Float
    public let isMuted: Bool
    public let repeatMode: RepeatMode
    public let shuffleModeEnabled: Bool
}

extension PlayerSnapshot {
    /// Reads the values of `player`, which mustn't change meanwhile.
    init(reading player: some Player) {
        playbackState = player.playbackState
        playWhenReady = player.playWhenReady
        isPlaying = player.isPlaying
        isLoading = player.isLoading
        playbackParameters = player.playbackParameters
        timeline = player.timeline
        currentMediaItemIndex = player.currentMediaItemIndex
        currentPeriodIndex = player.currentPeriodIndex
        currentMediaItem = player.currentMediaItem
        hasPreviousMediaItem = player.hasPreviousMediaItem
        hasNextMediaItem = player.hasNextMediaItem
        isCurrentMediaItemSeekable = player.isCurrentMediaItemSeekable
        isCurrentMediaItemDynamic = player.isCurrentMediaItemDynamic
        duration = player.duration
        currentPosition = player.currentPosition
        contentPosition = player.contentPosition
        bufferedPosition = player.bufferedPosition
        contentBufferedPosition = player.contentBufferedPosition
        totalBufferedDuration = player.totalBufferedDuration
        mediaMetadata = player.mediaMetadata
        videoSize = player.videoSize
        volume = player.volume
        isMuted = player.isMuted
        repeatMode = player.repeatMode
        shuffleModeEnabled = player.shuffleModeEnabled
    }
}
