//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import Dispatch

public protocol Player: AnyObject {
    @MainActor var delegate: MulticastDelegate<SEPlayerDelegate> { get }
    var playbackState: PlayerState { get }
    var isPlaying: Bool { get }
    var playWhenReady: Bool { get set }
    var repeatMode: RepeatMode { get set }
    var shuffleModeEnabled: Bool { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var isLoading: Bool { get }
    var seekBackIncrement: Int64 { get }
    var seekForwardIncrement: Int64 { get }
    var hasPreviousMediaItem: Bool { get }
    var maxSeekToPreviousPosition: Int64 { get }
    var hasNextMediaItem: Bool { get }
    var playbackParameters: PlaybackParameters { get set }
    var timeline: Timeline { get }
    var currentPeriodIndex: Int? { get }
    var currentMediaItemIndex: Int { get }
    var nextMediaItemIndex: Int? { get }
    var previousMediaItemIndex: Int? { get }
    var currentMediaItem: MediaItem? { get }
    var numberOfMediaItemsInPlaylist: Int { get }
    var duration: Int64 { get }
    var currentPosition: Int64 { get }
    var bufferedPosition: Int64 { get }
    var bufferedPercentage: Int { get }
    var totalBufferedDuration: Int64 { get }
    var isCurrentMediaItemDynamic: Bool { get }
    var isCurrentMediaItemSeekable: Bool { get }
    var contentDuration: Int64 { get }
    var contentPosition: Int64 { get }
    var contentBufferedPosition: Int64 { get }

    func set(mediaItems: [MediaItem])
    func set(mediaItems: [MediaItem], resetPosition: Bool)
    func set(mediaItems: [MediaItem], startIndex: Int, startPositionMs: Int64)
    func set(mediaItem: MediaItem)
    func set(mediaItem: MediaItem, startPositionMs: Int64)
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
    func seekToDefaultPosition()
    func seekToDefaultPosition(of mediaItemIndex: Int)
    func seek(to positionMs: Int64)
    func seek(to positionMs: Int64, of mediaItemIndex: Int)
    func seekBack()
    func seekForward()
    func seekToPreviousMediaItem()
    func seekToPrevious()
    func seekToNextMediaItem()
    func seekToNext()
    func setPlaybackSpeed(new playbackSpeed: Float)
    func stop()
    func release()
    func releaseAsync() async

    func mediaItem(at index: Int) -> MediaItem

    func register(_ bufferable: PlayerBufferable)
    func remove(_ bufferable: PlayerBufferable)
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
    let windowId: AnyHashable?
    let mediaItemIndex: Int?
    let mediaItem: MediaItem?
    let periodId: AnyHashable?
    let periodIndex: Int?
    let positionMs: Int64
    let contentPositionMs: Int64
}

@frozen public enum MediaItemTransitionReason {
    case `repeat`
    case auto
    case seek
    case playlistChanged
}
