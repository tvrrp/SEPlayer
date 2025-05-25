//
//  PlaylistTimeline.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.05.2025.
//

struct PlaylistTimeline: AbstractConcatenatedTimeline {
    let timelines: [Timeline]
    let shuffleOrder: ShuffleOrder
    let isAtomic: Bool = false

    private let _windowCount: Int
    private let _periodCount: Int
    private let firstWindowInChildIndices: [Int]
    private let firstPeriodInChildIndices: [Int]

    private let ids: [AnyHashable]
    private let childIndexById: [AnyHashable: Int]

    init(mediaSourceInfoHolders: [MediaSourceInfoHolder], shuffleOrder: ShuffleOrder) {
        self.init(
            timelines: mediaSourceInfoHolders.map { $0.timeline },
            ids: mediaSourceInfoHolders.map { $0.id },
            shuffleOrder: shuffleOrder
        )
    }

    init(timelines: [Timeline], ids: [AnyHashable], shuffleOrder: ShuffleOrder) {
        self.timelines = timelines
        self.ids = ids
        self.shuffleOrder = shuffleOrder

        let results = zip(timelines, ids).enumerated().reduce(
            into: (
                firstWindowInChildIndices: [Int](),
                firstPeriodInChildIndices: [Int](),
                childIndexById: [AnyHashable: Int](),
                windowCount: 0,
                periodCount: 0
            )
        ) { acc, item in
            let (index, (timeline, id)) = item
            acc.firstWindowInChildIndices.append(acc.windowCount)
            acc.firstPeriodInChildIndices.append(acc.periodCount)
            acc.childIndexById[id] = index
            acc.windowCount += timeline.windowCount()
            acc.periodCount += timeline.periodCount()
        }

        _windowCount = results.windowCount
        _periodCount = results.periodCount
        firstWindowInChildIndices = results.firstWindowInChildIndices
        firstPeriodInChildIndices = results.firstPeriodInChildIndices
        childIndexById = results.childIndexById
    }

    func childIndex(by periodIndex: Int) -> Int {
        firstPeriodInChildIndices.firstIndex(of: periodIndex) ?? .zero
    }

    func childIndexBy(windowIndex: Int) -> Int {
        firstWindowInChildIndices.firstIndex(of: windowIndex) ?? .zero
    }

    func childIndex(by childId: AnyHashable) -> Int {
        childIndexById[childId] ?? .zero
    }

    func timeline(by childIndex: Int) -> Timeline {
        timelines[childIndex]
    }

    func firstPeriodIndex(by childIndex: Int) -> Int {
        firstPeriodInChildIndices[childIndex]
    }

    func firstWindowIndex(by childIndex: Int) -> Int {
        firstWindowInChildIndices[childIndex]
    }

    func childId(by childIndex: Int) -> AnyHashable {
        ids[childIndex]
    }

    func windowCount() -> Int { _windowCount }
    func periodCount() -> Int { _periodCount }

    func copyWithPlaceholderTimeline(shuffleOrder: ShuffleOrder) -> PlaylistTimeline {
        return PlaylistTimeline(
            timelines: timelines.map { ForwardingTimelineImpl(timeline: $0) },
            ids: ids,
            shuffleOrder: shuffleOrder
        )
    }
}

private extension PlaylistTimeline {
    final class ForwardingTimelineImpl: ForwardingTimeline {
        private let window = Window()

        override func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
            var superPeriod = super.getPeriod(periodIndex: periodIndex, period: &period, setIds: setIds)
            superPeriod.isPlaceholder = true
            return superPeriod
        }
    }
}
