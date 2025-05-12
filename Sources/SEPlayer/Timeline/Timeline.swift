//
//  Timeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

protocol Timeline: Hashable {
    var windowCount: Int { get }
    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int?
    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int
    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int
    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int
    func getWindow(windowIndex: Int, defaultPositionProjectionUs: Int64) -> Window
    func getPeriodCount() -> Int
    
    func getPeriod(periodIndex: Int, setIds: Bool) -> Period
}

extension Timeline {
//    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int {
//        switch repeatMode {
//        case .off:
//            <#code#>
//        case .one:
//            <#code#>
//        case .all:
//            <#code#>
//        }
//    }
    func nextPeriodIndex(
        periodIndex: Int,
        period: Period,
        window: Window,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool
    ) -> Int? {
        let windowIndex = getPeriod(periodIndex: periodIndex).windowIndex
        if getWindow(windowIndex: windowIndex).lastPeriodIndex == periodIndex {
            let nextWindowIndex = nextWindowIndex(
                windowIndex: windowIndex,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled
            )
            if let nextWindowIndex {
                return getWindow(windowIndex: nextWindowIndex).firstPeriodIndex
            }
            return nextWindowIndex
        }
        return periodIndex + 1
    }

    func getWindow(windowIndex: Int) -> Window { getWindow(windowIndex: windowIndex, defaultPositionProjectionUs: .zero) }
    func getPeriod(periodIndex: Int) -> Period { getPeriod(periodIndex: periodIndex, setIds: false) }
}

struct Window: Hashable {
    let id: UUID

    let mediaItem: MediaItem
    let presentationStartTimeMs: Int64
    let windowStartTimeMs: Int64

    let isSeekable: Bool
    let isDynamic: Bool
    let isPlaceholder: Bool

    let defaultPositionUs: Int64
    let durationUs: Int64

    let firstPeriodIndex: Int
    let lastPeriodIndex: Int
    let positionInFirstPeriodUs: Int64

    init(
        id: UUID = Window.singleWindowId,
        mediaItem: MediaItem = Window.placeholderMediaItem,
        presentationStartTimeMs: Int64 = .zero,
        windowStartTimeMs: Int64 = .zero,
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
    static let singleWindowId = UUID()
    static let placeholderMediaItem = MediaItem(url: FileManager.default.temporaryDirectory)
}

struct Period: Hashable {
    let id: AnyHashable?
    let uuid: UUID?
    let windowIndex: Int
    let duration: Int64
    let positionInWindow: Int64
    let isPlaceholder: Bool

    init(id: AnyHashable? = nil, uuid: UUID? = nil, windowIndex: Int, duration: Int64, positionInWindow: Int64, isPlaceholder: Bool = false) {
        self.id = id
        self.uuid = uuid
        self.windowIndex = windowIndex
        self.duration = duration
        self.positionInWindow = positionInWindow
        self.isPlaceholder = isPlaceholder
    }
}
