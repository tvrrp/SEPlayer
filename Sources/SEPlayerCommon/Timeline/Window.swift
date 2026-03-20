//
//  Window.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import CoreMedia
import Foundation.NSUUID

public final class Window {
    public var id: AnyHashable
    public var mediaItem: MediaItem
    public var manifest: Any?
    public var presentationStartTime: CMTime = .zero
    public var windowStartTime: CMTime = .zero
    public var elapsedRealtimeEpochOffset: CMTime = .zero

    public var isSeekable: Bool = false
    public var isDynamic: Bool = false
    public var liveConfiguration: MediaItem.LiveConfiguration?
    public var isPlaceholder: Bool = false

    public var defaultPosition: CMTime = .zero
    public var duration: CMTime = .zero

    public var firstPeriodIndex: Int = .zero
    public var lastPeriodIndex: Int = .zero
    public var positionInFirstPeriod: CMTime = .zero

//    public var durationMs: Int64 {
//        return Time.usToMs(timeUs: durationUs)
//    }

    public var isLive: Bool {
        liveConfiguration != nil
    }

    public init() {
        id = Self.singleWindowId
        mediaItem = Self.placeholderMediaItem
    }

    @discardableResult
    public func set(
        id: AnyHashable,
        mediaItem: MediaItem,
        manifest: Any?,
        presentationStartTime: CMTime,
        windowStartTime: CMTime,
        elapsedRealtimeEpochOffset: CMTime,
        isSeekable: Bool,
        isDynamic: Bool,
        liveConfiguration: MediaItem.LiveConfiguration?,
        defaultPosition: CMTime,
        duration: CMTime,
        firstPeriodIndex: Int,
        lastPeriodIndex: Int,
        positionInFirstPeriod: CMTime
    ) -> Window {
        self.id = id
        self.mediaItem = mediaItem
        self.manifest = manifest
        self.presentationStartTime = presentationStartTime
        self.windowStartTime = windowStartTime
        self.elapsedRealtimeEpochOffset = elapsedRealtimeEpochOffset
        self.isSeekable = isSeekable
        self.isDynamic = isDynamic
        self.liveConfiguration = liveConfiguration
        self.defaultPosition = defaultPosition
        self.duration = duration
        self.firstPeriodIndex = firstPeriodIndex
        self.lastPeriodIndex = lastPeriodIndex
        self.positionInFirstPeriod = positionInFirstPeriod
        return self
    }
}

extension Window: Hashable {
    public static func == (lhs: Window, rhs: Window) -> Bool {
        guard lhs !== rhs else { return true }

        return lhs.id == rhs.id
            && lhs.mediaItem == rhs.mediaItem
            && lhs.presentationStartTime == rhs.presentationStartTime
            && lhs.windowStartTime == rhs.windowStartTime
            && lhs.elapsedRealtimeEpochOffset == rhs.elapsedRealtimeEpochOffset
            && lhs.isSeekable == rhs.isSeekable
            && lhs.isDynamic == rhs.isDynamic
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.defaultPosition == rhs.defaultPosition
            && lhs.duration == rhs.duration
            && lhs.firstPeriodIndex == rhs.firstPeriodIndex
            && lhs.lastPeriodIndex == rhs.lastPeriodIndex
            && lhs.positionInFirstPeriod == rhs.positionInFirstPeriod
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(mediaItem)
        hasher.combine(presentationStartTime)
        hasher.combine(windowStartTime)
        hasher.combine(elapsedRealtimeEpochOffset)
        hasher.combine(isSeekable)
        hasher.combine(isDynamic)
        hasher.combine(isPlaceholder)
        hasher.combine(defaultPosition)
        hasher.combine(duration)
        hasher.combine(firstPeriodIndex)
        hasher.combine(lastPeriodIndex)
        hasher.combine(positionInFirstPeriod)
    }
}

extension Window {
    nonisolated(unsafe) public static let singleWindowId: AnyHashable = UUID()
    public static let placeholderMediaItem = MediaItem.Builder()
        .setMediaId("com.SEPlayer.common.Timeline")
        .setUrl(URL(string: "about:blank")!)
        .build()
}
