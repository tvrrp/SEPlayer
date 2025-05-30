//
//  ForwardingTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

class ForwardingTimeline: Timeline {
    let timeline: Timeline

    init(timeline: Timeline) {
        self.timeline = timeline
    }

    func windowCount() -> Int { timeline.windowCount() }

    func nextWindowIndex(windowIndex: Int, repeatMode: SEPlayer.RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        timeline.nextWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: shuffleModeEnabled)
    }

    func previousWindowIndex(windowIndex: Int, repeatMode: SEPlayer.RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        timeline.previousWindowIndex(windowIndex: windowIndex, repeatMode: repeatMode, shuffleModeEnabled: shuffleModeEnabled)
    }

    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        timeline.lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
    }

    @discardableResult
    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
        timeline.getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: defaultPositionProjectionUs)
    }

    func periodCount() -> Int { timeline.periodCount() }

    @discardableResult
    func periodById(_ id: AnyHashable, period: inout Period) -> Period {
        defaultPeriodById(id, period: &period)
    }

    @discardableResult
    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
        timeline.getPeriod(periodIndex: periodIndex, period: &period, setIds: setIds)
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        timeline.indexOfPeriod(by: id)
    }

    func id(for periodIndex: Int) -> AnyHashable {
        timeline.id(for: periodIndex)
    }
}
