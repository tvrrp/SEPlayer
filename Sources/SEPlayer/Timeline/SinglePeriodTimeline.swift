//
//  SinglePeriodTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

struct SinglePeriodTimeline: Timeline {
    let windowCount: Int

    init(windowCount: Int = 1) {
        self.windowCount = windowCount
    }

    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        return .zero
    }

    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int {
        return .zero
    }

    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int {
        return .zero
    }

    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int {
        return .zero
    }

    func getWindow(windowIndex: Int, defaultPositionProjectionUs: Int64) -> Window {
        return Window()
    }

    func getPeriod(periodIndex: Int, setIds: Bool) -> Period {
        Period(windowIndex: .zero, duration: .zero, positionInWindow: .zero)
    }

    func getPeriodCount() -> Int {
        return .zero
    }
}
