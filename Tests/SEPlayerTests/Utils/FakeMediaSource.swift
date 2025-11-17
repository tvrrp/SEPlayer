//
//  FakeMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Foundation
import Testing
@testable import SEPlayer

class FakeMediaSource: BaseMediaSource {
    let queue: Queue
    private let trackGroups: [TrackGroup]
    private let trackDataFactory: FakeMediaPeriod.TrackDataFactory?
    private let syncSampleTimesUs: [Int64]?
    private var activeMediaPeriods: NSHashTable<FakeMediaPeriod>
    private var createdMediaPeriods: [MediaPeriodId]

    override var isSingleWindow: Bool {
        timeline == nil || timeline?.isEmpty == true || timeline?.windowCount() == 1
    }

    private var canUpdateMediaItems: Bool
    private var preparationAllowed: Bool
    private var timeline: Timeline?
    private var preparedSource = false
    private var releasedSource = false
    private var transferListener: TransferListener?
    private var periodDefersOnPreparedCallback = false

    convenience init(syncQueue: Queue) throws {
        try self.init(queue: syncQueue, timeline: FakeTimeline())
    }

    convenience init(queue: Queue, timeline: Timeline?, formats: [Format] = []) throws {
        try self.init(
            queue: queue,
            timeline: timeline,
            trackGroups: Self.buildTrackGroups(formats: formats)
        )
    }

    init(
        queue: Queue,
        timeline: Timeline? = nil,
        trackDataFactory: FakeMediaPeriod.TrackDataFactory? = nil,
        syncSampleTimesUs: [Int64]? = nil,
        trackGroups: [TrackGroup]
    ) {
        self.queue = queue
        self.trackGroups = trackGroups
        self.trackDataFactory = trackDataFactory
        self.syncSampleTimesUs = syncSampleTimesUs
        self.timeline = timeline
        preparationAllowed = true
        canUpdateMediaItems = true
        activeMediaPeriods = .init()
        createdMediaPeriods = []
        super.init(queue: queue)
    }

    func setAllowPreparation(_ allowPreparation: Bool, isolation: isolated (any Actor)? = #isolation) throws {
        assert(queue.isCurrent())
        preparationAllowed = allowPreparation
        if allowPreparation {
            isolation!.assertIsolated()
            try finishSourcePreparation(sendManifestLoadEvents: true)
        }
    }

    override func getMediaItem() -> MediaItem {
        assert(queue.isCurrent())
        guard let timeline, !timeline.isEmpty else {
            return .fakeMediaItem
        }

        var newWindow = Window()
        return timeline.getWindow(windowIndex: 0, window: &newWindow).mediaItem
    }

    func setCanUpdateMediaItems(_ canUpdateMediaItems: Bool, isolation: isolated (any Actor)? = #isolation) {
        assert(queue.isCurrent())
        self.canUpdateMediaItems = canUpdateMediaItems
    }

    override func canUpdateMediaItem(new item: MediaItem) -> Bool {
        canUpdateMediaItems
    }

    override func updateMediaItem(new item: MediaItem) throws {
        guard var timeline else { return }
        timeline = TimelineWithUpdatedMediaItem(timeline: timeline, updatedMediaItem: item)
        self.timeline = timeline
        if preparedSource, preparationAllowed {
            try refreshSourceInfo(timeline: timeline)
        }
    }

    override func getInitialTimeline() -> Timeline? {
        guard let timeline, !timeline.isEmpty, timeline.windowCount() != 1 else {
            return nil
        }

        return InitialTimeline(timeline: timeline)
    }

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) throws {
        #expect(!preparedSource)
        preparedSource = true
        releasedSource = false
        if preparationAllowed, timeline != nil {
            try finishSourcePreparation(sendManifestLoadEvents: true)
        }
    }

    override func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: Int64) throws -> MediaPeriod {
        #expect(preparedSource)
        #expect(!releasedSource)
        let timeline = try #require(timeline)
        let periodIndex = try #require(timeline.indexOfPeriod(by: id.periodId))
        var period = Period()
        period = timeline.getPeriod(periodIndex: periodIndex, period: &period)
        let mediaPeriod = try createMediaPeriod(
            id: id,
            trackGroups: trackGroups,
            allocator: allocator,
            transferListener: transferListener
        )
        activeMediaPeriods.add(mediaPeriod)
        createdMediaPeriods.append(id)
        return mediaPeriod
    }

    override func release(mediaPeriod: MediaPeriod) {
        #expect(preparedSource)
        #expect(!releasedSource)
        #expect(activeMediaPeriods.contains(mediaPeriod as? FakeMediaPeriod))
        activeMediaPeriods.remove(mediaPeriod as? FakeMediaPeriod)
        releaseMediaPeriod(mediaPeriod: mediaPeriod)
    }

    func releaseMediaPeriod(mediaPeriod: MediaPeriod) {
        (mediaPeriod as? FakeMediaPeriod)?.release()
    }

    override func releaseSourceInternal() {
        #expect(preparedSource)
        #expect(!releasedSource)
        #expect(activeMediaPeriods.count == 0)
        releasedSource = true
        preparedSource = false
    }

    func createMediaPeriod(
        id: MediaPeriodId,
        trackGroups: [TrackGroup],
        allocator: Allocator,
        transferListener: TransferListener?
    ) throws -> FakeMediaPeriod {
        let timeline = try #require(timeline)
        var period = Period()
        let positionInWindowUs = timeline.periodById(id.periodId, period: &period).positionInWindowUs
        let defaultFirstSampleTimeUs = positionInWindowUs >= 0 ? 0 : -positionInWindowUs
        return try FakeMediaPeriod(
            queue: queue,
            trackGroups: trackGroups,
            allocator: allocator,
            trackDataFactory: trackDataFactory ?? FakeMediaPeriod.DefaultTrackDataFactory
                .singleSampleWithTimeUs(sampleTimeUs: defaultFirstSampleTimeUs),
            syncSampleTimestampsUs: syncSampleTimesUs,
            deferOnPrepared: periodDefersOnPreparedCallback
        )
    }

    private func finishSourcePreparation(sendManifestLoadEvents: Bool) throws {
        try refreshSourceInfo(timeline: #require(timeline))
    }
}

extension FakeMediaSource {
    final class InitialTimeline: ForwardingTimeline, @unchecked Sendable {
        override func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
            var childWindow = timeline.getWindow(
                windowIndex: windowIndex,
                window: &window,
                defaultPositionProjectionUs: defaultPositionProjectionUs
            )
            childWindow.isDynamic = true
            childWindow.isSeekable = false
            return childWindow
        }
    }

    static func buildTrackGroups(formats: [Format]) throws -> [TrackGroup] {
        try formats.map { try TrackGroup(formats: [$0]) }
    }
}

private extension MediaItem {
    static let fakeMediaItem = MediaItem.Builder()
        .setMediaId("FakeMediaSource")
        .setUrl(URL(string: "http://manifest.url")!)
        .build()
}
