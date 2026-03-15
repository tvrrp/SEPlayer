//
//  BasePlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

public protocol BasePlayer: Player {
    var window: Window { get set }
    func seek(to mediaItemIndex: Int?, positionMs: Int64, isRepeatingCurrentItem: Bool)
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
        if bufferedPosition == .timeUnset || duration == .timeUnset {
            return .zero
        } else {
            return Int(duration == 0 ? 100 : max(0, min(((position * 100) / duration), 100)))
        }
    }

    public var isCurrentMediaItemDynamic: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).isDynamic
    }

    public var isCurrentMediaItemSeekable: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentPeriodIndex ?? .zero, window: window).isSeekable
    }

    public var contentDuration: Int64 {
        if timeline.isEmpty {
            return .timeUnset
        } else {
            return timeline.getWindow(
                windowIndex: currentMediaItemIndex,
                window: window
            ).durationMs
        }
    }
}

extension BasePlayer {
    public func set(mediaItem: MediaItem) {
        set(mediaItems: [mediaItem])
    }

    public func set(mediaItem: MediaItem, startPositionMs: Int64) {
        set(mediaItems: [mediaItem], startIndex: 0, startPositionMs: startPositionMs)
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
        seekTo(offsetMs: -seekBackIncrement)
    }

    public func seekForward() {
        seekTo(offsetMs: seekForwardIncrement)
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
            seekToCurrentItem(positionMs: .zero)
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

    public func seek(to positionMs: Int64) {
        seekToCurrentItem(positionMs: positionMs)
    }

    public func seek(to positionMs: Int64, of mediaItemIndex: Int) {
        seek(to: mediaItemIndex, positionMs: positionMs, isRepeatingCurrentItem: false)
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
        seek(to: nil, positionMs: .timeUnset, isRepeatingCurrentItem: false)
    }

    func seekToCurrentItem(positionMs: Int64) {
        seek(to: currentMediaItemIndex, positionMs: positionMs, isRepeatingCurrentItem: false)
    }

    func seekTo(offsetMs: Int64) {
        var positionMs = currentPosition + offsetMs
        let durationMs = duration
        if durationMs != .timeUnset {
            positionMs = min(positionMs, durationMs)
        }
        positionMs = max(positionMs, 0)
        seekToCurrentItem(positionMs: positionMs)
    }

    func seekToDefaultPositionInternal(mediaItemIndex: Int) {
        seek(to: mediaItemIndex, positionMs: .timeUnset, isRepeatingCurrentItem: false)
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
        seek(to: currentMediaItemIndex, positionMs: .timeUnset, isRepeatingCurrentItem: true)
    }
}
