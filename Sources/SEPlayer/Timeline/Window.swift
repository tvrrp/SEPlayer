//
//  Window.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.05.2025.
//

import Foundation

public struct Window: Hashable {
    var id: AnyHashable

    var mediaItem: MediaItem
    let presentationStartTimeMs: Int64
    let windowStartTimeMs: Int64
    let elapsedRealtimeEpochOffsetMs: Int64

    let isSeekable: Bool
    let isDynamic: Bool
    var isPlaceholder: Bool

    let defaultPositionUs: Int64
    let durationUs: Int64

    var firstPeriodIndex: Int
    var lastPeriodIndex: Int
    let positionInFirstPeriodUs: Int64

    var durationMs: Int64 {
        // TODO: convert
        return durationUs
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
    static let singleWindowId: AnyHashable = UUID()
    static let placeholderMediaItem = MediaItem(url: FileManager.default.temporaryDirectory)
}
