//
//  SinglePeriodTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSUUID
import SEPlayerCommon

final class SinglePeriodTimeline: Timeline, @unchecked Sendable {
    private static let uuid = UUID()
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
    private let manifest: Any?
    private let mediaItem: MediaItem
    private let liveConfiguration: MediaItem.LiveConfiguration?

    convenience init(
        durationUs: Int64,
        isSeekable: Bool,
        isDynamic: Bool,
        useLiveConfiguration: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
    ) {
        self.init(
            periodDurationUs: durationUs,
            windowDurationUs: durationUs,
            windowPositionInPeriodUs: 0,
            windowDefaultStartPositionUs: 0,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            useLiveConfiguration: useLiveConfiguration,
            manifest: manifest,
            mediaItem: mediaItem
        )
    }

    convenience init(
        periodDurationUs: Int64,
        windowDurationUs: Int64,
        windowPositionInPeriodUs: Int64,
        windowDefaultStartPositionUs: Int64,
        isSeekable: Bool,
        isDynamic: Bool,
        useLiveConfiguration: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
    ) {
        self.init(
            presentationStartTimeMs: .timeUnset,
            windowStartTimeMs: .timeUnset,
            elapsedRealtimeEpochOffsetMs: .timeUnset,
            periodDurationUs: periodDurationUs,
            windowDurationUs: windowDurationUs,
            windowPositionInPeriodUs: windowPositionInPeriodUs,
            windowDefaultStartPositionUs: windowDefaultStartPositionUs,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            suppressPositionProjection: false,
            manifest: manifest,
            mediaItem: mediaItem,
            liveConfiguration: useLiveConfiguration ? mediaItem.liveConfiguration : nil
        )
    }

    init(
        presentationStartTimeMs: Int64,
        windowStartTimeMs: Int64,
        elapsedRealtimeEpochOffsetMs: Int64,
        periodDurationUs: Int64,
        windowDurationUs: Int64,
        windowPositionInPeriodUs: Int64,
        windowDefaultStartPositionUs: Int64,
        isSeekable: Bool,
        isDynamic: Bool,
        suppressPositionProjection: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
        liveConfiguration: MediaItem.LiveConfiguration?
    ) {
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
        self.manifest = manifest
        self.mediaItem = mediaItem
        self.liveConfiguration = liveConfiguration
    }

    func windowCount() -> Int { 1 }

    func getWindow(windowIndex: Int, window: Window, defaultPositionProjectionUs: Int64) -> Window {
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

        return window.set(
            id: Window.singleWindowId,
            mediaItem: mediaItem,
            manifest: manifest,
            presentationStartTimeMs: presentationStartTimeMs,
            windowStartTimeMs: windowStartTimeMs,
            elapsedRealtimeEpochOffsetMs: elapsedRealtimeEpochOffsetMs,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            liveConfiguration: liveConfiguration,
            defaultPositionUs: windowDefaultStartPositionUs,
            durationUs: windowDurationUs,
            firstPeriodIndex: 0,
            lastPeriodIndex: 0,
            positionInFirstPeriodUs: windowPositionInPeriodUs
        )
    }

    func periodCount() -> Int { 1 }

    func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
        period.set(
            id: nil,
            uid: setIds ? Self.uuid : nil,
            windowIndex: 0,
            durationUs: periodDurationUs,
            positionInWindowUs: -windowPositionInPeriodUs
        )
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        (Self.uuid as AnyHashable) == id ? 0 : nil
    }

    func id(for periodIndex: Int) -> AnyHashable {
        return Self.uuid
    }
}
