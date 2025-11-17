//
//  FakeTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Foundation
import Testing
@testable import SEPlayer

struct FakeTimeline: Timeline {
    private var windowDefinitions: [TimelineWindowDefinition]
    private var periodOffsets: [Int]
    private let shuffleOrder: ShuffleOrder

    init(
        windowCount: Int = 1,
        windowDefinitions: [TimelineWindowDefinition]? = nil,
        shuffleOrder: ShuffleOrder? = nil
    ) {
        self.windowDefinitions = windowDefinitions ?? Self.createDefaultWindowDefinitions(windowCount: windowCount)
        self.shuffleOrder = shuffleOrder ?? DefaultShuffleOrder(length: self.windowDefinitions.count)
        var periodOffsets = Array(repeating: 0, count: self.windowDefinitions.count + 1)
        periodOffsets[0] = 0
        for index in 0..<self.windowDefinitions.count {
            periodOffsets[index + 1] = periodOffsets[index] + self.windowDefinitions[index].periodCount
        }
        self.periodOffsets = periodOffsets
    }

    func windowCount() -> Int { windowDefinitions.count }

    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        guard repeatMode != .one else { return windowIndex }

        if windowIndex == lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
            return repeatMode == .all ? firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) : nil
        }

        return shuffleModeEnabled ? shuffleOrder.nextIndex(index: windowIndex) : windowIndex + 1
    }

    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        guard repeatMode != .one else { return windowIndex }

        if windowIndex == lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
            return repeatMode == .all ? lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) : nil
        }

        return shuffleModeEnabled ? shuffleOrder.nextIndex(index: windowIndex) : windowIndex - 1
    }

    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        shuffleModeEnabled ? shuffleOrder.lastIndex : _lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        shuffleModeEnabled ? shuffleOrder.firstIndex : _firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
        let windowDefinition = windowDefinitions[windowIndex]
        var windowDurationUs = Int64.zero
        var period = Period()

        for index in periodOffsets[windowIndex..<windowIndex + 1] {
            let periodDurationUs = getPeriod(periodIndex: index, period: &period).durationUs
            if index == periodOffsets[windowIndex] && periodDurationUs != 0 {
                windowDurationUs -= windowDefinition.windowOffsetInFirstPeriodUs
            }
            if periodDurationUs == .timeUnset {
                windowDurationUs = .timeUnset
                break
            }
            windowDurationUs += periodDurationUs
        }

        window = Window(
            id: windowDefinition.id,
            mediaItem: windowDefinition.mediaItem,
            presentationStartTimeMs: .timeUnset,
            elapsedRealtimeEpochOffsetMs: .timeUnset,
            isSeekable: windowDefinition.isSeekable,
            isDynamic: windowDefinition.isDynamic,
            isPlaceholder: windowDefinition.isPlaceholder,
            defaultPositionUs: windowDefinition.defaultPositionUs,
            durationUs: windowDefinition.durationUs,
            firstPeriodIndex: periodOffsets[windowIndex],
            lastPeriodIndex: periodOffsets[windowIndex + 1] - 1,
            positionInFirstPeriodUs: windowDefinition.windowOffsetInFirstPeriodUs
        )

        return window
    }

    func periodCount() -> Int {
        periodOffsets[periodOffsets.count - 1]
    }

    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
        let windowIndex = Util.binarySearch(array: periodOffsets, value: periodIndex, inclusive: true, stayInBounds: false)
        let windowPeriodIndex = periodIndex - periodOffsets[windowIndex]
        let windowDefinition = windowDefinitions[windowIndex]
        let id = setIds ? windowPeriodIndex : nil
        let uid = setIds ? ConcatenatedId(windowDefinition.id, windowPeriodIndex) : nil
        var periodDurationUs = if periodIndex == windowDefinition.periodCount - 1, windowDefinition.durationUs == .timeUnset {
            Int64.timeUnset
        } else {
            windowDefinition.durationUs / Int64(windowDefinition.periodCount)
        }
        let positionInWindowUs: Int64
        if windowPeriodIndex == 0 {
            if windowDefinition.durationUs != .timeUnset {
                periodDurationUs += windowDefinition.windowOffsetInFirstPeriodUs
            }
            positionInWindowUs = -windowDefinition.windowOffsetInFirstPeriodUs
        } else {
            positionInWindowUs = periodDurationUs * Int64(windowPeriodIndex)
        }

        period = Period(
            id: id,
            uid: uid,
            windowIndex: windowIndex,
            durationUs: periodDurationUs,
            positionInWindowUs: positionInWindowUs,
            isPlaceholder: windowDefinition.isPlaceholder
        )

        return period
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        (0..<periodCount()).first(where: { self.id(for: $0) == id })
    }

    func id(for periodIndex: Int) -> AnyHashable {
        let windowIndex = Util.binarySearch(array: periodOffsets, value: periodIndex, inclusive: true, stayInBounds: false)
        let windowPeriodIndex = periodIndex - periodOffsets[windowIndex]
        let windowDefinition = windowDefinitions[windowIndex]
        return ConcatenatedId(windowDefinition.id, windowPeriodIndex)
    }
}

extension FakeTimeline {
    struct TimelineWindowDefinition: @unchecked Sendable {
        static let defaultWindowDurationUs: Int64 = 10 * .microsecondsPerSecond
        static let defaultWindowOffsetInFirstPeriodUs: Int64 = 123 * .microsecondsPerSecond

        let periodCount: Int
        let id: AnyHashable
        let mediaItem: MediaItem
        let isSeekable: Bool
        let isDynamic: Bool
        let isLive: Bool
        let isPlaceholder: Bool
        let durationUs: Int64
        let defaultPositionUs: Int64
        let windowStartTimeUs: Int64
        let windowOffsetInFirstPeriodUs: Int64
        let adPlaybackStates: [AdPlaybackState]

        init(
            periodCount: Int = 1,
            id: AnyHashable = 0,
            isSeekable: Bool = true,
            isDynamic: Bool = false,
            isLive: Bool = false,
            isPlaceholder: Bool = false,
            durationUs: Int64 = Self.defaultWindowDurationUs,
            defaultPositionUs: Int64 = 0,
            windowStartTimeUs: Int64 = .timeUnset,
            windowOffsetInFirstPeriodUs: Int64 = Self.defaultWindowOffsetInFirstPeriodUs,
            adPlaybackStates: [AdPlaybackState] = [],
            mediaItem: MediaItem? = nil
        ) {
            precondition(durationUs != .timeUnset || periodCount == 1)
            self.periodCount = periodCount
            self.id = id
            self.isSeekable = isSeekable
            self.isDynamic = isDynamic
            self.isLive = isLive
            self.isPlaceholder = isPlaceholder
            self.durationUs = durationUs
            self.defaultPositionUs = defaultPositionUs
            self.windowStartTimeUs = windowStartTimeUs
            self.windowOffsetInFirstPeriodUs = windowOffsetInFirstPeriodUs
            self.mediaItem = mediaItem ?? FakeTimeline.fakeMediaItem.buildUpon().setTag(id).build()
            self.adPlaybackStates = adPlaybackStates
        }
    }
}

extension FakeTimeline {
    static func createDefaultWindowDefinitions(windowCount: Int) -> [TimelineWindowDefinition] {
        (0..<windowCount).map { TimelineWindowDefinition(id: $0) }
    }
}

extension FakeTimeline {
    static let fakeMediaItem = MediaItem.Builder()
        .setMediaId("FakeTimeline")
        .setUrl(URL(string: "about:blank")!)
        .build()
}
