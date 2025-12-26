//
//  Window.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import Foundation.NSUUID

public final class Window {
    internal(set) public var id: AnyHashable
    internal(set) public var mediaItem: MediaItem

    private(set) public var presentationStartTimeMs: Int64 = .zero
    private(set) public var windowStartTimeMs: Int64 = .zero
    private(set) public var elapsedRealtimeEpochOffsetMs: Int64 = .zero

    internal(set) public var isSeekable: Bool = false
    internal(set) public var isDynamic: Bool = false
    internal(set) public var isPlaceholder: Bool = false

    private(set) public var defaultPositionUs: Int64 = .zero
    private(set) public var durationUs: Int64 = .zero

    internal(set) public var firstPeriodIndex: Int = .zero
    internal(set) public var lastPeriodIndex: Int = .zero
    private(set) public var positionInFirstPeriodUs: Int64 = .zero

    public var durationMs: Int64 {
        return Time.usToMs(timeUs: durationUs)
    }

    init() {
        id = Self.singleWindowId
        mediaItem = Self.placeholderMediaItem
    }

    @discardableResult
    func set(
        id: AnyHashable,
        mediaItem: MediaItem,
        presentationStartTimeMs: Int64,
        windowStartTimeMs: Int64,
        elapsedRealtimeEpochOffsetMs: Int64,
        isSeekable: Bool,
        isDynamic: Bool,
        defaultPositionUs: Int64,
        durationUs: Int64,
        firstPeriodIndex: Int,
        lastPeriodIndex: Int,
        positionInFirstPeriodUs: Int64
    ) -> Window {
        self.id = id
        self.mediaItem = mediaItem
        self.presentationStartTimeMs = presentationStartTimeMs
        self.windowStartTimeMs = windowStartTimeMs
        self.elapsedRealtimeEpochOffsetMs = elapsedRealtimeEpochOffsetMs
        self.isSeekable = isSeekable
        self.isDynamic = isDynamic
        self.defaultPositionUs = defaultPositionUs
        self.durationUs = durationUs
        self.firstPeriodIndex = firstPeriodIndex
        self.lastPeriodIndex = lastPeriodIndex
        self.positionInFirstPeriodUs = positionInFirstPeriodUs
        return self
    }
}

extension Window: Hashable {
    public static func == (lhs: Window, rhs: Window) -> Bool {
        guard lhs !== rhs else { return true }

        return lhs.id == rhs.id
            && lhs.mediaItem == rhs.mediaItem
            && lhs.presentationStartTimeMs == rhs.presentationStartTimeMs
            && lhs.windowStartTimeMs == rhs.windowStartTimeMs
            && lhs.elapsedRealtimeEpochOffsetMs == rhs.elapsedRealtimeEpochOffsetMs
            && lhs.isSeekable == rhs.isSeekable
            && lhs.isDynamic == rhs.isDynamic
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.defaultPositionUs == rhs.defaultPositionUs
            && lhs.durationUs == rhs.durationUs
            && lhs.firstPeriodIndex == rhs.firstPeriodIndex
            && lhs.lastPeriodIndex == rhs.lastPeriodIndex
            && lhs.positionInFirstPeriodUs == rhs.positionInFirstPeriodUs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(mediaItem)
        hasher.combine(presentationStartTimeMs)
        hasher.combine(windowStartTimeMs)
        hasher.combine(elapsedRealtimeEpochOffsetMs)
        hasher.combine(isSeekable)
        hasher.combine(isDynamic)
        hasher.combine(isPlaceholder)
        hasher.combine(defaultPositionUs)
        hasher.combine(durationUs)
        hasher.combine(firstPeriodIndex)
        hasher.combine(lastPeriodIndex)
        hasher.combine(positionInFirstPeriodUs)
    }
}

extension Window {
    public static let singleWindowId: AnyHashable = UUID()
    public static let placeholderMediaItem = MediaItem.Builder()
        .setMediaId("com.SEPlayer.common.Timeline")
        .setUrl(URL(string: "about:blank")!)
        .build()
}
