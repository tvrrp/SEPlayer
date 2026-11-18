//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia
import Dispatch

/// A player, usable from any thread. Its delegates hear the changes on the main queue.
public protocol Player: AnyObject, Sendable {
    @MainActor var delegate: MulticastDelegate<SEPlayerDelegate> { get }
    /// The values below as of one moment: read several of them from here, as the player may change between reads.
    var snapshot: PlayerSnapshot { get }
    var playbackState: PlayerState { get }
    var isPlaying: Bool { get }
    var playWhenReady: Bool { get set }
    var repeatMode: RepeatMode { get set }
    var shuffleModeEnabled: Bool { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    /// How the player shares the app's audio session with other players and with the audio of other apps.
    var audioSessionPolicy: AudioSessionPolicy { get set }
    var isLoading: Bool { get }
    var seekBackIncrement: CMTime { get }
    var seekForwardIncrement: CMTime { get }
    var hasPreviousMediaItem: Bool { get }
    var maxSeekToPreviousPosition: CMTime { get }
    var hasNextMediaItem: Bool { get }
    var playbackParameters: PlaybackParameters { get set }
    var timeline: Timeline { get }
    var currentPeriodIndex: Int? { get }
    var currentMediaItemIndex: Int { get }
    var nextMediaItemIndex: Int? { get }
    var previousMediaItemIndex: Int? { get }
    var currentMediaItem: MediaItem? { get }
    var numberOfMediaItemsInPlaylist: Int { get }
    var duration: CMTime { get }
    var currentPosition: CMTime { get }
    var bufferedPosition: CMTime { get }
    var bufferedPercentage: Int { get }
    var totalBufferedDuration: CMTime { get }
    var isCurrentMediaItemDynamic: Bool { get }
    var isCurrentMediaItemSeekable: Bool { get }
    var contentDuration: CMTime { get }
    var contentPosition: CMTime { get }
    var contentBufferedPosition: CMTime { get }

    /// The tracks of the current media item, with whether each is supported and selected. Empty until they are
    /// known.
    ///
    /// Every track of an adaptive selection counts as selected: which of them plays changes with the network.
    var currentTracks: Tracks { get }

    /// The parameters constraining the track selection.
    ///
    /// Setting them reselects the tracks for the media loaded from now on: what is buffered plays out first, so
    /// playback isn't interrupted. Calls ``SEPlayerDelegate/player(_:didChangeTrackSelectionParameters:)``.
    var trackSelectionParameters: TrackSelectionParameters { get set }

    /// The metadata of the current media item: what its ``MediaItem`` says.
    var mediaMetadata: MediaMetadata { get }

    /// The metadata of the playlist, as set by the app.
    var playlistMetadata: MediaMetadata { get set }

    /// The size of the video being played: ``VideoSize/unknown`` before there is video.
    var videoSize: VideoSize { get }

    func set(mediaItems: [MediaItem])
    func set(mediaItems: [MediaItem], resetPosition: Bool)
    func set(mediaItems: [MediaItem], startIndex: Int, startPosition: CMTime)
    func set(mediaItem: MediaItem)
    func set(mediaItem: MediaItem, startPosition: CMTime)
    func set(mediaItem: MediaItem, resetPosition: Bool)
    func append(mediaItem: MediaItem)
    func insert(mediaItem: MediaItem, at position: Int)
    func append(mediaItems: [MediaItem])
    func insert(mediaItems: [MediaItem], at position: Int)
    func moveMediaItem(from index: Int, to newIndex: Int)
    func moveMediaItems(range: Range<Int>, to newIndex: Int)
    func replace(mediaItem: MediaItem, at index: Int)
    func replace(mediaItems: [MediaItem], at range: Range<Int>)
    func removeMediaItem(at index: Int)
    func removeMediaItems(at range: Range<Int>)
    func clearMediaItems()

    func prepare()
    func play()
    func pause()
    func seekToDefaultPosition(completion: ((Bool) -> Void)?)
    func seekToDefaultPosition(of mediaItemIndex: Int, completion: ((Bool) -> Void)?)
    func seek(to position: CMTime, seekParameters: SeekParameters, completion: ((Bool) -> Void)?)
    func seek(to position: CMTime, of mediaItemIndex: Int, seekParameters: SeekParameters, completion: ((Bool) -> Void)?)
    func seekBack(seekParameters: SeekParameters, completion: ((Bool) -> Void)?)
    func seekForward(seekParameters: SeekParameters, completion: ((Bool) -> Void)?)
    func seekToPreviousMediaItem(completion: ((Bool) -> Void)?)
    func seekToPrevious(completion: ((Bool) -> Void)?)
    func seekToNextMediaItem(completion: ((Bool) -> Void)?)
    func seekToNext(completion: ((Bool) -> Void)?)
    func setPlaybackSpeed(new playbackSpeed: Float)
    func stop()
    func release()
    func releaseAsync() async

    func mediaItem(at index: Int) -> MediaItem
}

public extension Player {
    func seekToDefaultPosition() {
        seekToDefaultPosition(completion: nil)
    }

    func seekToDefaultPosition(of mediaItemIndex: Int) {
        seekToDefaultPosition(of: mediaItemIndex, completion: nil)
    }

    func seek(to position: CMTime) {
        seek(to: position, seekParameters: .default, completion: nil)
    }

    func seek(to position: CMTime, completion: @escaping ((Bool) -> Void)) {
        seek(to: position, seekParameters: .default, completion: completion)
    }

    func seek(to position: CMTime, seekParameters: SeekParameters) {
        seek(to: position, seekParameters: seekParameters, completion: nil)
    }

    func seek(to position: CMTime, of mediaItemIndex: Int) {
        seek(to: position, of: mediaItemIndex, seekParameters: .default, completion: nil)
    }

    func seek(to position: CMTime, of mediaItemIndex: Int, completion: @escaping ((Bool) -> Void)) {
        seek(to: position, of: mediaItemIndex, seekParameters: .default, completion: completion)
    }

    func seek(to position: CMTime, of mediaItemIndex: Int, seekParameters: SeekParameters) {
        seek(to: position, of: mediaItemIndex, seekParameters: seekParameters, completion: nil)
    }

    func seekBack() {
        seekBack(seekParameters: .default, completion: nil)
    }

    func seekBack(completion: @escaping ((Bool) -> Void)) {
        seekBack(seekParameters: .default, completion: completion)
    }

    func seekBack(seekParameters: SeekParameters) {
        seekBack(seekParameters: seekParameters, completion: nil)
    }

    func seekForward() {
        seekForward(seekParameters: .default, completion: nil)
    }

    func seekForward(completion: @escaping ((Bool) -> Void)) {
        seekForward(seekParameters: .default, completion: completion)
    }

    func seekForward(seekParameters: SeekParameters) {
        seekForward(seekParameters: seekParameters, completion: nil)
    }

    func seekToPreviousMediaItem() {
        seekToPreviousMediaItem(completion: nil)
    }

    func seekToPrevious() {
        seekToPrevious(completion: nil)
    }

    func seekToNextMediaItem() {
        seekToNextMediaItem(completion: nil)
    }

    func seekToNext() {
        seekToNext(completion: nil)
    }
}

@frozen public enum PlayerState: Equatable {
    case idle
    case buffering
    case ready
    case ended
}

@frozen public enum PlayWhenReadyChangeReason {
    case userRequest
    case audioSessionInterruption
    case routeChanged
    case endOfMediaItem
}

@frozen public enum PlaybackSuppressionReason {
    case none
    case audioSessionLoss
}

@frozen public enum RepeatMode {
    case off
    case one
    case all
}

@frozen public enum DiscontinuityReason {
    case autoTransition
    case seek
    case seekAdjustment
    case skip
    case remove
    case `internal`
}

@frozen public enum TimelineChangeReason {
    case playlistChanged
    case sourceUpdate
}

public struct PositionInfo: Hashable {
    public let windowId: AnyHashable?
    public let mediaItemIndex: Int?
    public let mediaItem: MediaItem?
    public let periodId: AnyHashable?
    public let periodIndex: Int?
    public let position: CMTime
    public let contentPosition: CMTime

    public init(
        windowId: AnyHashable?,
        mediaItemIndex: Int?,
        mediaItem: MediaItem?,
        periodId: AnyHashable?,
        periodIndex: Int?,
        position: CMTime,
        contentPosition: CMTime
    ) {
        self.windowId = windowId
        self.mediaItemIndex = mediaItemIndex
        self.mediaItem = mediaItem
        self.periodId = periodId
        self.periodIndex = periodIndex
        self.position = position
        self.contentPosition = contentPosition
    }
}

@frozen public enum MediaItemTransitionReason {
    case `repeat`
    case auto
    case seek
    case playlistChanged
}
