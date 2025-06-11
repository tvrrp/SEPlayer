//
//  AbstractConcatenatedTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.05.2025.
//

protocol AbstractConcatenatedTimeline: Timeline {
    var shuffleOrder: ShuffleOrder { get }
    var isAtomic: Bool { get }

    func childIndex(by periodIndex: Int) -> Int
    func childIndexBy(windowIndex: Int) -> Int
    func childIndex(by childId: AnyHashable) -> Int
    func timeline(by childIndex: Int) -> Timeline
    func firstPeriodIndex(by childIndex: Int) -> Int
    func firstWindowIndex(by childIndex: Int) -> Int
    func childId(by childIndex: Int) -> AnyHashable
}

extension AbstractConcatenatedTimeline {
    var childCount: Int { shuffleOrder.count }

    static func childTimelineId(from concatenatedId: AnyHashable) -> AnyHashable {
        (concatenatedId as! ConcatenatedId).first
    }

    static func childPeriodId(from concatenatedId: AnyHashable) -> AnyHashable {
        (concatenatedId as! ConcatenatedId).second
    }

    static func concatenatedId(childTimelineId: AnyHashable, childPeriodOrWindowId: AnyHashable) -> AnyHashable {
        ConcatenatedId(childTimelineId, childPeriodOrWindowId)
    }

    func nextWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        var shuffleModeEnabled = shuffleModeEnabled
        var repeatMode = repeatMode

        if isAtomic {
            repeatMode = repeatMode == .one ? .all : repeatMode
            shuffleModeEnabled = false
        }

        let childIndex = childIndexBy(windowIndex: windowIndex)
        let firstWindowIndexInChild = firstWindowIndex(by: childIndex)
        let nextWindowIndexInChild = timeline(by: childIndex)
            .nextWindowIndex(
                windowIndex: windowIndex - firstWindowIndexInChild,
                repeatMode: repeatMode == .all ? .off : repeatMode,
                shuffleModeEnabled: shuffleModeEnabled
            )

        if let nextWindowIndexInChild {
            return firstWindowIndexInChild + nextWindowIndexInChild
        }

        var nextChildIndex = getNextChildIndex(childIndex: childIndex, shuffleModeEnabled: shuffleModeEnabled)
        while let unwrappedChildIndex = nextChildIndex, timeline(by: unwrappedChildIndex).isEmpty {
            nextChildIndex = getNextChildIndex(childIndex: unwrappedChildIndex, shuffleModeEnabled: shuffleModeEnabled)
        }

        if let nextChildIndex {
            return firstWindowIndex(by: nextChildIndex)
                + (timeline(by: nextChildIndex).firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) ?? .zero)
        }

        if repeatMode == .all {
            return firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
        }

        return nil
    }

    func previousWindowIndex(windowIndex: Int, repeatMode: RepeatMode, shuffleModeEnabled: Bool) -> Int? {
        var shuffleModeEnabled = shuffleModeEnabled
        var repeatMode = repeatMode

        if isAtomic {
            repeatMode = repeatMode == .one ? .all : repeatMode
            shuffleModeEnabled = false
        }

        let childIndex = childIndexBy(windowIndex: windowIndex)
        let firstWindowIndexInChild = firstWindowIndex(by: childIndex)
        let previousWindowIndexInChild = timeline(by: childIndex)
            .previousWindowIndex(
                windowIndex: windowIndex - firstWindowIndexInChild,
                repeatMode: repeatMode == .all ? .off : repeatMode,
                shuffleModeEnabled: shuffleModeEnabled
            )

        if let previousWindowIndexInChild {
            return firstWindowIndexInChild + previousWindowIndexInChild
        }

        var previousChildIndex = getPreviousChildIndex(childIndex: childIndex, shuffleModeEnabled: shuffleModeEnabled)
        while let unwrappedChildIndex = previousChildIndex, timeline(by: unwrappedChildIndex).isEmpty {
            previousChildIndex = getPreviousChildIndex(childIndex: unwrappedChildIndex, shuffleModeEnabled: shuffleModeEnabled)
        }

        if let previousChildIndex {
            return firstWindowIndex(by: previousChildIndex)
                + (timeline(by: previousChildIndex).lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) ?? .zero)
        }

        if repeatMode == .all {
            return lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
        }

        return nil
    }

    func lastWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        guard childCount != 0 else { return nil }

        let shuffleModeEnabled = isAtomic ? false : shuffleModeEnabled
        var lastChildIndex = shuffleModeEnabled ? shuffleOrder.lastIndex : childCount - 1

        while let unwrappedChildIndex = lastChildIndex, timeline(by: unwrappedChildIndex).isEmpty {
            lastChildIndex = getPreviousChildIndex(childIndex: unwrappedChildIndex, shuffleModeEnabled: shuffleModeEnabled)
            if lastChildIndex == nil {
                return nil
            }
        }

        guard let lastChildIndex else { return nil }

        return firstWindowIndex(by: lastChildIndex)
            + (timeline(by: lastChildIndex).lastWindowIndex(shuffleModeEnabled: shuffleModeEnabled) ?? .zero)
    }

    func firstWindowIndex(shuffleModeEnabled: Bool) -> Int? {
        guard childCount != 0 else { return nil }

        let shuffleModeEnabled = isAtomic ? false : shuffleModeEnabled
        var firstChildIndex = shuffleModeEnabled ? shuffleOrder.firstIndex : 0

        while let unwrappedChildIndex = firstChildIndex, timeline(by: unwrappedChildIndex).isEmpty {
            firstChildIndex = getNextChildIndex(childIndex: unwrappedChildIndex, shuffleModeEnabled: shuffleModeEnabled)
            if firstChildIndex == nil {
                return nil
            }
        }

        guard let firstChildIndex else { return nil }

        return firstWindowIndex(by: firstChildIndex)
            + (timeline(by: firstChildIndex).firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) ?? .zero)
    }

    func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
        let childIndex = childIndexBy(windowIndex: windowIndex)
        let firstWindowIndexInChild = firstWindowIndex(by: childIndex)
        let firstPeriodIndexInChild = firstPeriodIndex(by: childIndex)

        timeline(by: childIndex).getWindow(
            windowIndex: windowIndex - firstWindowIndexInChild,
            window: &window,
            defaultPositionProjectionUs: defaultPositionProjectionUs
        )

        let childId = childId(by: childIndex)
        window.id = window.id == Window.singleWindowId ? childId : Self.concatenatedId(childTimelineId: childId, childPeriodOrWindowId: window.id)
        window.firstPeriodIndex += firstPeriodIndexInChild
        window.lastPeriodIndex += firstPeriodIndexInChild

        return window
    }

    func periodById(_ id: AnyHashable, period: inout Period) -> Period {
        let childId = Self.childTimelineId(from: id)
        let childPeriodId = Self.childPeriodId(from: id)
        let childIndex = childIndex(by: childId)
        let firstWindowIndexInChild = firstWindowIndex(by: childIndex)
        timeline(by: childIndex).periodById(childPeriodId, period: &period)
        period.windowIndex += firstWindowIndexInChild
        period.uid = id
        return period
    }

    func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
        let childIndex = childIndex(by: periodIndex)
        let firstWindowIndexInChild = firstWindowIndex(by: childIndex)
        let firstPeriodIndexInChild = firstPeriodIndex(by: childIndex)
        timeline(by: childIndex)
            .getPeriod(
                periodIndex: periodIndex - firstPeriodIndexInChild,
                period: &period,
                setIds: setIds
            )
        period.windowIndex += firstWindowIndexInChild
        if setIds, let id = period.uid {
            period.uid = Self.concatenatedId(
                childTimelineId: childId(by: childIndex),
                childPeriodOrWindowId: id
            )
        }
        return period
    }

    func indexOfPeriod(by id: AnyHashable) -> Int? {
        guard let concatenatedId = id as? ConcatenatedId else { return nil }

        let childId = Self.childTimelineId(from: concatenatedId)
        let childPeriodId = Self.childPeriodId(from: concatenatedId)

        let childIndex = childIndex(by: childId)
        let periodIndexInChild = timeline(by: childIndex).indexOfPeriod(by: childPeriodId)
        if let periodIndexInChild {
            return firstPeriodIndex(by: childIndex) + periodIndexInChild
        } else {
            return nil
        }
    }

    func id(for periodIndex: Int) -> AnyHashable {
        let childIndex = childIndex(by: periodIndex)
        let firstPeriodIndexInChild = firstPeriodIndex(by: childIndex)
        let periodIdInChild = timeline(by: childIndex).id(for: periodIndex - firstPeriodIndexInChild)

        return Self.concatenatedId(
            childTimelineId: childId(by: childIndex),
            childPeriodOrWindowId: periodIdInChild
        )
    }

    private func getNextChildIndex(childIndex: Int, shuffleModeEnabled: Bool) -> Int? {
        if shuffleModeEnabled {
            return shuffleOrder.nextIndex(index: childIndex)
        } else {
            return childIndex < childCount - 1 ? childIndex + 1 : nil
        }
    }

    private func getPreviousChildIndex(childIndex: Int, shuffleModeEnabled: Bool) -> Int? {
        if shuffleModeEnabled {
            return shuffleOrder.previousIndex(index: childIndex)
        } else {
            return childIndex > 0 ? childIndex - 1 : nil
        }
    }
}

private struct ConcatenatedId: Hashable {
    let first: AnyHashable
    let second: AnyHashable

    init(_ first: AnyHashable, _ second: AnyHashable) {
        self.first = first
        self.second = second
    }
}
