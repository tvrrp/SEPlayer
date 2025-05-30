//
//  SinglePeriodTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSUUID

struct SinglePeriodTimeline: Timeline {
    static let uuid = UUID()
    private let mediaItem: MediaItem
    private let presentationStartTimeMs: Int64
    private let windowStartTimeMs: Int64
    private let elapsedRealtimeEpochOffsetMs: Int64
    private let periodDurationUs: Int64
    private let windowDurationUs: Int64
    private let windowPositionInPeriodUs: Int64
    private let windowDefaultStartPositionUs: Int64
    private let isSeekable: Bool
    private let isDynamic: Bool
    private let suppressPositionProjection: Bool

    init(
        mediaItem: MediaItem,
        presentationStartTimeMs: Int64 = .timeUnset,
        windowStartTimeMs: Int64 = .timeUnset,
        elapsedRealtimeEpochOffsetMs: Int64 = .timeUnset,
        periodDurationUs: Int64,
        windowDurationUs: Int64,
        windowPositionInPeriodUs: Int64 = .zero,
        windowDefaultStartPositionUs: Int64 = .zero,
        isSeekable: Bool,
        isDynamic: Bool,
        suppressPositionProjection: Bool = false
    ) {
        self.mediaItem = mediaItem
        self.presentationStartTimeMs = presentationStartTimeMs
        self.windowStartTimeMs = windowStartTimeMs
        self.elapsedRealtimeEpochOffsetMs = elapsedRealtimeEpochOffsetMs
        self.periodDurationUs = periodDurationUs
        self.windowDurationUs = windowDurationUs
        self.windowPositionInPeriodUs = windowPositionInPeriodUs
        self.windowDefaultStartPositionUs = windowDefaultStartPositionUs
        self.isSeekable = isSeekable
        self.isDynamic = isDynamic
        self.suppressPositionProjection = suppressPositionProjection
    }

    func windowCount() -> Int { 1 }

    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
        var windowDefaultStartPositionUs = windowDefaultStartPositionUs

        if isDynamic, !suppressPositionProjection, defaultPositionProjectionUs != 0 {
            if windowDurationUs != .timeUnset {
                windowDefaultStartPositionUs = .timeUnset
            } else {
                windowDefaultStartPositionUs += defaultPositionProjectionUs
                if windowDefaultStartPositionUs > windowDurationUs {
                    windowDefaultStartPositionUs = .timeUnset
                }
            }
        }

        window = Window(
            id: Window.singleWindowId,
            mediaItem: mediaItem,
            presentationStartTimeMs: presentationStartTimeMs,
            windowStartTimeMs: windowStartTimeMs,
            elapsedRealtimeEpochOffsetMs: elapsedRealtimeEpochOffsetMs,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            isPlaceholder: window.isPlaceholder,
            defaultPositionUs: windowDefaultStartPositionUs,
            durationUs: windowDurationUs,
            firstPeriodIndex: 0,
            lastPeriodIndex: 0,
            positionInFirstPeriodUs: windowPositionInPeriodUs
        )

        return window
    }

    func periodCount() -> Int { 1 }

    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
        period = Period(
            id: nil,
            uid: setIds ? Self.uuid : nil,
            windowIndex: 0,
            durationUs: periodDurationUs,
            positionInWindowUs: -windowPositionInPeriodUs,
            isPlaceholder: false
        )

        return period
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        (Self.uuid as AnyHashable) == id ? 0 : nil
    }

    func id(for periodIndex: Int) -> AnyHashable {
        return Self.uuid
    }
}
