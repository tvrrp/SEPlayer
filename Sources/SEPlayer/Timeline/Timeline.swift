//
//  Timeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSUUID

public let emptyTimeline: Timeline = EmptyTimeline()

public protocol Timeline: Sendable {
    func windowCount() -> Int
    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int?
    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int?
    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int?
    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int?
    @discardableResult
    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window
    func periodCount() -> Int
    @discardableResult
    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period
    @discardableResult
    func periodById(_ id: AnyHashable, period: inout Period) -> Period
    func indexOfPeriod(by id: AnyHashable) -> Int?
    func id(for periodIndex: Int) -> AnyHashable
}

public extension Timeline {
    var isEmpty: Bool { windowCount() == .zero }

    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        switch repeatMode {
        case .off:
            return if windowIndex == lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
                nil
            } else {
                windowIndex + 1
            }
        case .one:
            return windowIndex
        case .all:
            return if windowIndex == lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
                firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            } else {
                windowIndex + 1
            }
        }
    }

    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        switch repeatMode {
        case .off:
            return if windowIndex == firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
                nil
            } else {
                windowIndex - 1
            }
        case .one:
            return windowIndex
        case .all:
            return if windowIndex == firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) {
                lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            } else {
                windowIndex - 1
            }
        }
    }

    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        isEmpty ? nil : windowCount() - 1
    }

    internal func _lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        isEmpty ? nil : windowCount() - 1
    }

    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        isEmpty ? nil : 0
    }

    internal func _firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        isEmpty ? nil : 0
    }

    @discardableResult
    func getWindow(windowIndex: Int, window: inout Window) -> Window {
        getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: .zero)
    }

    func nextPeriodIndex(
        periodIndex: Int,
        period: inout Period,
        window: inout Window,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool
    ) -> Int? {
        let windowIndex = getPeriod(periodIndex: periodIndex, period: &period).windowIndex
        if getWindow(windowIndex: windowIndex, window: &window).lastPeriodIndex == periodIndex {
            let nextWindowIndex = nextWindowIndex(
                windowIndex: windowIndex,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled
            )
            if let nextWindowIndex {
                return getWindow(windowIndex: nextWindowIndex, window: &window).firstPeriodIndex
            }
            return nextWindowIndex
        }
        return periodIndex + 1
    }

    func isLastPeriod(
        periodIndex: Int,
        period: inout Period,
        window: inout Window,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool
    ) -> Bool {
        nil == nextPeriodIndex(
            periodIndex: periodIndex,
            period: &period,
            window: &window,
            repeatMode: repeatMode,
            shuffleModeEnabled: shuffleModeEnabled
        )
    }

    func periodPositionUs(
        window: inout Window,
        period: inout Period,
        windowIndex: Int,
        windowPositionUs: Int64,
        defaultPositionProjectionUs: Int64 = .zero
    ) -> (AnyHashable, Int64)? {
        guard windowIndex > 0 || windowIndex < windowCount() else {
            assertionFailure()
            return nil
        }
        getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: defaultPositionProjectionUs)
        let windowPositionUs = windowPositionUs == .timeUnset ? window.defaultPositionUs : windowPositionUs
        guard windowPositionUs != .timeUnset else { return nil }

        var periodIndex = window.firstPeriodIndex
        getPeriod(periodIndex: periodIndex, period: &period)
        while periodIndex < window.lastPeriodIndex,
              period.positionInWindowUs != windowPositionUs,
              getPeriod(periodIndex: periodIndex + 1, period: &period).positionInWindowUs <= windowPositionUs {
            periodIndex += 1
        }
        getPeriod(periodIndex: periodIndex, period: &period, setIds: true)
        var periodPositionUs = windowPositionUs - period.positionInWindowUs
        if periodPositionUs != .timeUnset {
            periodPositionUs = min(periodPositionUs, period.durationUs - 1)
        }
        periodPositionUs = max(0, periodPositionUs)
        guard let periodId = period.uid else { return nil }
        return (periodId, periodPositionUs)
    }

    @discardableResult
    func periodById(_ id: AnyHashable, period: inout Period) -> Period {
        defaultPeriodById(id, period: &period)
    }

    internal func defaultPeriodById(_ id: AnyHashable, period: inout Period) -> Period {
        getPeriod(periodIndex: indexOfPeriod(by: id) ?? .zero, period: &period, setIds: true)
    }

    @discardableResult
    func getPeriod(periodIndex: Int, period: inout Period) -> Period {
        getPeriod(periodIndex: periodIndex, period: &period, setIds: false)
    }

    func equals(to other: Timeline) -> Bool {
        if self.conformsToClass(), other.conformsToClass(),
           (self as AnyObject) === (other as AnyObject) {
            return true
        }

        guard other.windowCount() == windowCount() || other.periodCount() == periodCount() else {
            return false
        }

        var window = Window()
        var period = Period()
        var otherWindow = Window()
        var otherPeriod = Period()

        for index in 0..<windowCount() {
            if getWindow(windowIndex: index, window: &window) != other.getWindow(windowIndex: index, window: &otherWindow) {
                return false
            }
        }

        for index in 0..<periodCount() {
            if getPeriod(periodIndex: index, period: &period) != other.getPeriod(periodIndex: index, period: &otherPeriod) {
                return false
            }
        }

        var windowIndex = firstWindowIndex(shuffleModeEnabled: true)
        if windowIndex != other.firstWindowIndex(shuffleModeEnabled: true) {
            return false
        }

        let lastWindowIndex = lastWindowIndex(shuffleModeEnabled: true)
        if lastWindowIndex != other.lastWindowIndex(shuffleModeEnabled: true) {
            return false
        }

        while let unwrappedWindowIndex = windowIndex, windowIndex != lastWindowIndex {
            let nextWindowIndex = nextWindowIndex(
                windowIndex: unwrappedWindowIndex,
                repeatMode: .off,
                shuffleModeEnabled: true
            )
            let otherNextWindowIndex = other.nextWindowIndex(
                windowIndex: unwrappedWindowIndex,
                repeatMode: .off,
                shuffleModeEnabled: true
            )

            if nextWindowIndex != otherNextWindowIndex {
                return false
            }
            windowIndex = nextWindowIndex
        }

        return true
    }

    private func conformsToClass() -> Bool {
        let mirror = Mirror(reflecting: self)
        return mirror.displayStyle == .class
    }
}

private final class EmptyTimeline: Timeline {
    func windowCount() -> Int { 0 }
    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window { window }
    func periodCount() -> Int { 0 }
    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period { period }
    func indexOfPeriod(by id: AnyHashable) -> Int? { nil }
    func id(for periodIndex: Int) -> AnyHashable { UUID() }
    init() {}
}
