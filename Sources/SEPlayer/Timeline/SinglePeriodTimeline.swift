//
//  SinglePeriodTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation.NSUUID
import SEPlayerCommon

final class SinglePeriodTimeline: Timeline, @unchecked Sendable {
    private static let uuid = UUID()
    private let presentationStartTime: CMTime
    private let windowStartTime: CMTime
    private let elapsedRealtimeEpochOffset: CMTime
    private let periodDuration: CMTime
    private let windowDuration: CMTime
    private let windowPositionInPeriod: CMTime
    private let windowDefaultStartPosition: CMTime
    private let isSeekable: Bool
    private let isDynamic: Bool
    private let suppressPositionProjection: Bool
    private let manifest: Any?
    private let mediaItem: MediaItem
    private let liveConfiguration: MediaItem.LiveConfiguration?

    convenience init(
        duration: CMTime,
        isSeekable: Bool,
        isDynamic: Bool,
        useLiveConfiguration: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
    ) {
        self.init(
            periodDuration: duration,
            windowDuration: duration,
            windowPositionInPeriod: .zero,
            windowDefaultStartPosition: .zero,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            useLiveConfiguration: useLiveConfiguration,
            manifest: manifest,
            mediaItem: mediaItem
        )
    }

    convenience init(
        periodDuration: CMTime,
        windowDuration: CMTime,
        windowPositionInPeriod: CMTime,
        windowDefaultStartPosition: CMTime,
        isSeekable: Bool,
        isDynamic: Bool,
        useLiveConfiguration: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
    ) {
        self.init(
            presentationStartTime: .invalid,
            windowStartTime: .invalid,
            elapsedRealtimeEpochOffset: .invalid,
            periodDuration: periodDuration,
            windowDuration: windowDuration,
            windowPositionInPeriod: windowPositionInPeriod,
            windowDefaultStartPosition: windowDefaultStartPosition,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            suppressPositionProjection: false,
            manifest: manifest,
            mediaItem: mediaItem,
            liveConfiguration: useLiveConfiguration ? mediaItem.liveConfiguration : nil
        )
    }

    init(
        presentationStartTime: CMTime,
        windowStartTime: CMTime,
        elapsedRealtimeEpochOffset: CMTime,
        periodDuration: CMTime,
        windowDuration: CMTime,
        windowPositionInPeriod: CMTime,
        windowDefaultStartPosition: CMTime,
        isSeekable: Bool,
        isDynamic: Bool,
        suppressPositionProjection: Bool,
        manifest: Any?,
        mediaItem: MediaItem,
        liveConfiguration: MediaItem.LiveConfiguration?
    ) {
        self.presentationStartTime = presentationStartTime
        self.windowStartTime = windowStartTime
        self.elapsedRealtimeEpochOffset = elapsedRealtimeEpochOffset
        self.periodDuration = periodDuration
        self.windowDuration = windowDuration
        self.windowPositionInPeriod = windowPositionInPeriod
        self.windowDefaultStartPosition = windowDefaultStartPosition
        self.isSeekable = isSeekable
        self.isDynamic = isDynamic
        self.suppressPositionProjection = suppressPositionProjection
        self.manifest = manifest
        self.mediaItem = mediaItem
        self.liveConfiguration = liveConfiguration
    }

    func windowCount() -> Int { 1 }

    func getWindow(windowIndex: Int, window: Window, defaultPositionProjection: CMTime) -> Window {
        var windowDefaultStartPosition = windowDefaultStartPosition

        if isDynamic, !suppressPositionProjection, defaultPositionProjection != .zero {
            if windowDuration.isValid {
                windowDefaultStartPosition = .invalid
            } else {
                windowDefaultStartPosition = windowDefaultStartPosition + defaultPositionProjection
                if windowDefaultStartPosition > windowDuration {
                    windowDefaultStartPosition = .invalid
                }
            }
        }

        return window.set(
            id: Window.singleWindowId,
            mediaItem: mediaItem,
            manifest: manifest,
            presentationStartTime: presentationStartTime,
            windowStartTime: windowStartTime,
            elapsedRealtimeEpochOffset: elapsedRealtimeEpochOffset,
            isSeekable: isSeekable,
            isDynamic: isDynamic,
            liveConfiguration: liveConfiguration,
            defaultPosition: windowDefaultStartPosition,
            duration: windowDuration,
            firstPeriodIndex: 0,
            lastPeriodIndex: 0,
            positionInFirstPeriod: windowPositionInPeriod
        )
    }

    func periodCount() -> Int { 1 }

    func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
        period.set(
            id: nil,
            uid: setIds ? Self.uuid : nil,
            windowIndex: 0,
            duration: periodDuration,
            positionInWindow: CMTimeMultiply(windowPositionInPeriod, multiplier: -1)
        )
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        (Self.uuid as AnyHashable) == id ? 0 : nil
    }

    func id(for periodIndex: Int) -> AnyHashable {
        return Self.uuid
    }
}
