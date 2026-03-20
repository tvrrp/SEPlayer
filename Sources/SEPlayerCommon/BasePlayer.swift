//
//  BasePlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia

public protocol BasePlayer: Player {
    var window: Window { get set }
    func seek(to mediaItemIndex: Int?, position: CMTime, isRepeatingCurrentItem: Bool)
}

extension BasePlayer {
    public var isPlaying: Bool {
        playbackState == .ready && playWhenReady
    }

    public var hasPreviousMediaItem: Bool {
        previousMediaItemIndex != nil
    }

    public var hasNextMediaItem: Bool {
        nextMediaItemIndex != nil
    }

    public var nextMediaItemIndex: Int? {
        timeline.isEmpty ? nil : timeline.nextWindowIndex(
            windowIndex: currentMediaItemIndex,
            repeatMode: repeatModeForNavigation,
            shuffleModeEnabled: shuffleModeEnabled
        )
    }

    public var previousMediaItemIndex: Int? {
        timeline.isEmpty ? nil : timeline.previousWindowIndex(
            windowIndex: currentMediaItemIndex,
            repeatMode: repeatModeForNavigation,
            shuffleModeEnabled: shuffleModeEnabled
        )
    }

    public var currentMediaItem: MediaItem? {
        timeline.isEmpty ? nil : timeline.getWindow(
            windowIndex: currentMediaItemIndex,
            window: window
        ).mediaItem
    }

    public var numberOfMediaItemsInPlaylist: Int {
        timeline.windowCount()
    }

    public var bufferedPercentage: Int {
        let position = bufferedPosition
        let duration = duration
        if !bufferedPosition.isValid || !duration.isValid {
            return .zero
        } else {
//            return Int(duration == .zero ? 100 : max(0, min(((position * 100) / duration), 100)))
            // TODO: fix
            return .zero
        }
    }

    public var isCurrentMediaItemDynamic: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).isDynamic
    }

    public var isCurrentMediaItemSeekable: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentPeriodIndex ?? .zero, window: window).isSeekable
    }

    public var contentDuration: CMTime {
        if timeline.isEmpty {
            return .invalid
        } else {
            return timeline.getWindow(
                windowIndex: currentMediaItemIndex,
                window: window
            ).duration
        }
    }
}

extension BasePlayer {
    public func set(mediaItem: MediaItem) {
        set(mediaItems: [mediaItem])
    }

    public func set(mediaItem: MediaItem, startPosition: CMTime) {
        set(mediaItems: [mediaItem], startIndex: 0, startPosition: startPosition)
    }

    public func set(mediaItem: MediaItem, resetPosition: Bool) {
        set(mediaItems: [mediaItem], resetPosition: resetPosition)
    }

    public func set(mediaItems: [MediaItem]) {
        set(mediaItems: mediaItems, resetPosition: true)
    }

    public func insert(mediaItem: MediaItem, at position: Int) {
        insert(mediaItems: [mediaItem], at: position)
    }

    public func append(mediaItem: MediaItem) {
        append(mediaItems: [mediaItem])
    }

    public func append(mediaItems: [MediaItem]) {
        insert(mediaItems: mediaItems, at: .max)
    }

    public func moveMediaItem(from index: Int, to newIndex: Int) {
        if index != newIndex {
            moveMediaItems(
                range: Range<Int>(index...index + 1),
                to: newIndex
            )
        }
    }

    public func replace(mediaItem: MediaItem, at index: Int) {
        replace(mediaItems: [mediaItem], at: Range<Int>(index...index + 1))
    }

    public func removeMediaItem(at index: Int) {
        removeMediaItems(at: Range(index...index + 1))
    }

    public func clearMediaItems() {
        removeMediaItems(at: Range(0...Int.max - 1))
    }

    public func play() {
        playWhenReady = true
    }

    public func pause() {
        playWhenReady = false
    }

    public func seekToDefaultPosition() {
        seekToDefaultPositionInternal(mediaItemIndex: currentMediaItemIndex)
    }

    public func seekToDefaultPosition(of mediaItemIndex: Int) {
        seekToDefaultPositionInternal(mediaItemIndex: mediaItemIndex)
    }

    public func seekBack() {
        seekTo(offset: CMTimeMultiply(seekBackIncrement, multiplier: -1))
    }

    public func seekForward() {
        seekTo(offset: seekForwardIncrement)
    }

    public func seekToPreviousMediaItem() {
        seekToPreviousMediaItemInternal()
    }

    public func seekToPrevious() {
        let timeline = timeline
        if timeline.isEmpty {
            ignoreSeek()
            return
        }

        let hasPreviousMediaItem = hasPreviousMediaItem
        if hasPreviousMediaItem, currentPosition <= maxSeekToPreviousPosition {
            seekToPreviousMediaItemInternal()
        } else {
            seekToCurrentItem(position: .zero)
        }
    }

    public func seekToNextMediaItem() {
        seekToNextMediaItemInternal()
    }

    public func seekToNext() {
        let timeline = timeline
        if timeline.isEmpty {
            ignoreSeek()
            return
        }

        if hasNextMediaItem {
            seekToNextMediaItemInternal()
        } else {
            ignoreSeek()
        }
    }

    public func seek(to position: CMTime) {
        seekToCurrentItem(position: position)
    }

    public func seek(to position: CMTime, of mediaItemIndex: Int) {
        seek(to: mediaItemIndex, position: position, isRepeatingCurrentItem: false)
    }

    public func setPlaybackSpeed(new playbackSpeed: Float) {
        playbackParameters.newSpeed(playbackSpeed)
    }

    public func mediaItem(at index: Int) -> MediaItem {
        timeline.getWindow(windowIndex: index, window: window).mediaItem
    }

    public func release() {
        Task { await releaseAsync() }
    }
}

private extension BasePlayer {
    var repeatModeForNavigation: RepeatMode {
        repeatMode == .one ? .off : repeatMode
    }

    func ignoreSeek() {
        seek(to: nil, position: .invalid, isRepeatingCurrentItem: false)
    }

    func seekToCurrentItem(position: CMTime) {
        seek(to: currentMediaItemIndex, position: position, isRepeatingCurrentItem: false)
    }

    func seekTo(offset: CMTime) {
        var position = currentPosition + offset
        let duration = duration
        if duration.isValid {
            position = min(position, duration)
        }
        position = max(position, .zero)
        seekToCurrentItem(position: position)
    }

    func seekToDefaultPositionInternal(mediaItemIndex: Int) {
        seek(to: mediaItemIndex, position: .invalid, isRepeatingCurrentItem: false)
    }

    func seekToNextMediaItemInternal() {
        guard let nextMediaItemIndex else {
            ignoreSeek()
            return
        }
        if nextMediaItemIndex == currentMediaItemIndex {
            repeatCurrentMediaItem()
        } else {
            seekToDefaultPositionInternal(mediaItemIndex: nextMediaItemIndex)
        }
    }

    func seekToPreviousMediaItemInternal() {
        guard let previousMediaItemIndex else {
            ignoreSeek()
            return
        }
        
        if previousMediaItemIndex == currentMediaItemIndex {
            repeatCurrentMediaItem();
        } else {
            seekToDefaultPositionInternal(mediaItemIndex: previousMediaItemIndex);
        }
    }

    private func repeatCurrentMediaItem() {
        seek(to: currentMediaItemIndex, position: .invalid, isRepeatingCurrentItem: true)
    }
}
