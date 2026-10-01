//
//  BasePlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import CoreMedia

public protocol BasePlayer: Player {
    var window: Window { get set }

    func seek(
        to mediaItemIndex: Int?,
        position: CMTime,
        isRepeatingCurrentItem: Bool,
        seekParameters: SeekParameters,
        completion: ((Bool) -> Void)?
    )
}

public extension BasePlayer {
    var isPlaying: Bool {
        playbackState == .ready && playWhenReady
    }

    var hasPreviousMediaItem: Bool {
        previousMediaItemIndex != nil
    }

    var hasNextMediaItem: Bool {
        nextMediaItemIndex != nil
    }

    var nextMediaItemIndex: Int? {
        timeline.isEmpty ? nil : timeline.nextWindowIndex(
            windowIndex: currentMediaItemIndex,
            repeatMode: repeatModeForNavigation,
            shuffleModeEnabled: shuffleModeEnabled
        )
    }

    var previousMediaItemIndex: Int? {
        timeline.isEmpty ? nil : timeline.previousWindowIndex(
            windowIndex: currentMediaItemIndex,
            repeatMode: repeatModeForNavigation,
            shuffleModeEnabled: shuffleModeEnabled
        )
    }

    var currentMediaItem: MediaItem? {
        timeline.isEmpty ? nil : timeline.getWindow(
            windowIndex: currentMediaItemIndex,
            window: window
        ).mediaItem
    }

    var numberOfMediaItemsInPlaylist: Int {
        timeline.windowCount()
    }

    var bufferedPercentage: Int {
        let duration = duration
        if !bufferedPosition.isValid || !duration.isValid {
            return .zero
        } else {
//            return Int(duration == .zero ? 100 : max(0, min(((position * 100) / duration), 100)))
            // TODO: fix
            return .zero
        }
    }

    var isCurrentMediaItemDynamic: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).isDynamic
    }

    var isCurrentMediaItemSeekable: Bool {
        !timeline.isEmpty && timeline.getWindow(windowIndex: currentPeriodIndex ?? .zero, window: window).isSeekable
    }

    var contentDuration: CMTime {
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

public extension BasePlayer {
    func set(mediaItem: MediaItem) {
        set(mediaItems: [mediaItem])
    }

    func set(mediaItem: MediaItem, startPosition: CMTime) {
        set(mediaItems: [mediaItem], startIndex: 0, startPosition: startPosition)
    }

    func set(mediaItem: MediaItem, resetPosition: Bool) {
        set(mediaItems: [mediaItem], resetPosition: resetPosition)
    }

    func set(mediaItems: [MediaItem]) {
        set(mediaItems: mediaItems, resetPosition: true)
    }

    func insert(mediaItem: MediaItem, at position: Int) {
        insert(mediaItems: [mediaItem], at: position)
    }

    func append(mediaItem: MediaItem) {
        append(mediaItems: [mediaItem])
    }

    func append(mediaItems: [MediaItem]) {
        insert(mediaItems: mediaItems, at: .max)
    }

    func moveMediaItem(from index: Int, to newIndex: Int) {
        if index != newIndex {
            moveMediaItems(
                range: Range<Int>(index...index + 1),
                to: newIndex
            )
        }
    }

    func replace(mediaItem: MediaItem, at index: Int) {
        replace(mediaItems: [mediaItem], at: Range<Int>(index...index + 1))
    }

    func removeMediaItem(at index: Int) {
        removeMediaItems(at: Range(index...index + 1))
    }

    func clearMediaItems() {
        removeMediaItems(at: Range(0...Int.max - 1))
    }

    func play() {
        playWhenReady = true
    }

    func pause() {
        playWhenReady = false
    }

    func release() {
        Task { await releaseAsync() }
    }

    func setPlaybackSpeed(new playbackSpeed: Float) {
        playbackParameters.newSpeed(playbackSpeed)
    }

    func mediaItem(at index: Int) -> MediaItem {
        timeline.getWindow(windowIndex: index, window: window).mediaItem
    }
}

public extension BasePlayer {
    func seekToDefaultPosition(completion: ((Bool) -> Void)?) {
        seekToDefaultPositionInternal(mediaItemIndex: currentMediaItemIndex, completion: completion)
    }

    func seekToDefaultPosition(of mediaItemIndex: Int, completion: ((Bool) -> Void)?) {
        seekToDefaultPositionInternal(mediaItemIndex: mediaItemIndex, completion: completion)
    }

    func seekBack(seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        seekTo(
            offset: CMTimeMultiply(
                seekBackIncrement,
                multiplier: -1
            ),
            seekParameters: seekParameters,
            completion: completion
        )
    }

    func seekForward(seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        seekTo(
            offset: seekForwardIncrement,
            seekParameters: seekParameters,
            completion: completion
        )
    }

    func seekToPreviousMediaItem(completion: ((Bool) -> Void)?) {
        seekToPreviousMediaItemInternal(completion: completion)
    }

    func seekToPrevious(completion: ((Bool) -> Void)?) {
        let timeline = timeline
        if timeline.isEmpty {
            ignoreSeek(completion: completion)
            return
        }

        let hasPreviousMediaItem = hasPreviousMediaItem
        if hasPreviousMediaItem, currentPosition <= maxSeekToPreviousPosition {
            seekToPreviousMediaItemInternal(completion: completion)
        } else {
            seekToCurrentItem(position: .zero, seekParameters: .exact, completion: completion)
        }
    }

    func seekToNextMediaItem(completion: ((Bool) -> Void)?) {
        seekToNextMediaItemInternal(completion: completion)
    }

    func seekToNext(completion: ((Bool) -> Void)?) {
        let timeline = timeline
        if timeline.isEmpty {
            ignoreSeek(completion: completion)
            return
        }

        if hasNextMediaItem {
            seekToNextMediaItemInternal(completion: completion)
        } else {
            ignoreSeek(completion: completion)
        }
    }

    func seek(to position: CMTime, seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        seekToCurrentItem(position: position, seekParameters: seekParameters, completion: completion)
    }

    func seek(to position: CMTime, of mediaItemIndex: Int, seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        seek(
            to: mediaItemIndex,
            position: position,
            isRepeatingCurrentItem: false,
            seekParameters: seekParameters,
            completion: completion
        )
    }
}

private extension BasePlayer {
    var repeatModeForNavigation: RepeatMode {
        repeatMode == .one ? .off : repeatMode
    }

    func ignoreSeek(completion: ((Bool) -> Void)?) {
        seek(
            to: nil,
            position: .invalid,
            isRepeatingCurrentItem: false,
            seekParameters: .default,
            completion: completion
        ) 
    }

    func seekToCurrentItem(position: CMTime, seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        seek(
            to: currentMediaItemIndex,
            position: position,
            isRepeatingCurrentItem: false,
            seekParameters: seekParameters,
            completion: completion
        )
    }

    func seekTo(offset: CMTime, seekParameters: SeekParameters, completion: ((Bool) -> Void)?) {
        var position = currentPosition + offset
        let duration = duration
        if duration.isValid {
            position = min(position, duration)
        }
        position = max(position, .zero)
        seekToCurrentItem(position: position, seekParameters: seekParameters, completion: completion)
    }

    func seekToDefaultPositionInternal(
        mediaItemIndex: Int,
        completion: ((Bool) -> Void)?
    ) {
        seek(
            to: mediaItemIndex,
            position: .invalid,
            isRepeatingCurrentItem: false,
            seekParameters: .default,
            completion: completion
        )
    }

    func seekToNextMediaItemInternal(completion: ((Bool) -> Void)?) {
        guard let nextMediaItemIndex else {
            ignoreSeek(completion: completion)
            return
        }
        if nextMediaItemIndex == currentMediaItemIndex {
            repeatCurrentMediaItem(completion: completion)
        } else {
            seekToDefaultPositionInternal(mediaItemIndex: nextMediaItemIndex, completion: completion)
        }
    }

    func seekToPreviousMediaItemInternal(completion: ((Bool) -> Void)?) {
        guard let previousMediaItemIndex else {
            ignoreSeek(completion: completion)
            return
        }
        
        if previousMediaItemIndex == currentMediaItemIndex {
            repeatCurrentMediaItem(completion: completion)
        } else {
            seekToDefaultPositionInternal(mediaItemIndex: previousMediaItemIndex, completion: completion)
        }
    }

    private func repeatCurrentMediaItem(completion: ((Bool) -> Void)?) {
        seek(
            to: currentMediaItemIndex,
            position: .invalid,
            isRepeatingCurrentItem: true,
            seekParameters: .default,
            completion: completion
        )
    }
}
