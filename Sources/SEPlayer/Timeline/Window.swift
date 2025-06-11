//
//  Window.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import Foundation.NSUUID

public struct Window: Hashable {
    internal(set) public var id: AnyHashable

    internal(set) public var mediaItem: MediaItem
    public let presentationStartTimeMs: Int64
    public let windowStartTimeMs: Int64
    public let elapsedRealtimeEpochOffsetMs: Int64

    public let isSeekable: Bool
    public let isDynamic: Bool
    internal(set) public var isPlaceholder: Bool

    public let defaultPositionUs: Int64
    public let durationUs: Int64

    internal(set) public var firstPeriodIndex: Int
    internal(set) public var lastPeriodIndex: Int
    public let positionInFirstPeriodUs: Int64

    public var durationMs: Int64 {
        return Time.usToMs(timeUs: durationUs)
    }

    init(
        id: AnyHashable = Window.singleWindowId,
        mediaItem: MediaItem = Window.placeholderMediaItem,
        presentationStartTimeMs: Int64 = .zero,
        windowStartTimeMs: Int64 = .zero,
        elapsedRealtimeEpochOffsetMs: Int64 = .zero,
        isSeekable: Bool = false,
        isDynamic: Bool = false,
        isPlaceholder: Bool = false,
        defaultPositionUs: Int64 = .zero,
        durationUs: Int64 = .zero,
        firstPeriodIndex: Int = .zero,
        lastPeriodIndex: Int = .zero,
        positionInFirstPeriodUs: Int64 = .zero
    ) {
        self.id = id
        self.mediaItem = mediaItem
        self.presentationStartTimeMs = presentationStartTimeMs
        self.windowStartTimeMs = windowStartTimeMs
        self.elapsedRealtimeEpochOffsetMs = elapsedRealtimeEpochOffsetMs
        self.isSeekable = isSeekable
        self.isDynamic = isDynamic
        self.isPlaceholder = isPlaceholder
        self.defaultPositionUs = defaultPositionUs
        self.durationUs = durationUs
        self.firstPeriodIndex = firstPeriodIndex
        self.lastPeriodIndex = lastPeriodIndex
        self.positionInFirstPeriodUs = positionInFirstPeriodUs
    }
}

extension Window {
    public static let singleWindowId: AnyHashable = UUID()
    public static let placeholderMediaItem = MediaItem(url: FileManager.default.temporaryDirectory)
}
