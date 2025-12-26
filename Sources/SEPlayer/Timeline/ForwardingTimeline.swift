//
//  ForwardingTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

public class ForwardingTimeline: Timeline, @unchecked Sendable {
    public let timeline: Timeline

    public init(timeline: Timeline) {
        self.timeline = timeline
    }

    public func windowCount() -> Int { timeline.windowCount() }

    public func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        timeline.nextWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: shuffleModeEnabled)
    }

    public func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        timeline.previousWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: shuffleModeEnabled)
    }

    public func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        timeline.lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    public func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    @discardableResult
    public func getWindow(windowIndex: Int, window: Window, defaultPositionProjectionUs: Int64) -> Window {
        timeline.getWindow(windowIndex: windowIndex, window: window, defaultPositionProjectionUs: defaultPositionProjectionUs)
    }

    public func periodCount() -> Int { timeline.periodCount() }

    @discardableResult
    public func periodById(_ id: AnyHashable, period: Period) -> Period {
        defaultPeriodById(id, period: period)
    }

    @discardableResult
    public func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
        timeline.getPeriod(periodIndex: periodIndex, period: period, setIds: setIds)
    }

    public func indexOfPeriod(by id: AnyHashable) -> Int? {
        timeline.indexOfPeriod(by: id)
    }

    public func id(for periodIndex: Int) -> AnyHashable {
        timeline.id(for: periodIndex)
    }
}
