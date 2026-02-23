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
    private let trackGroupArray: TrackGroupArray
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

    convenience init(syncQueue: Queue = playerSyncQueue) throws {
        try self.init(queue: syncQueue, timeline: FakeTimeline())
    }

    convenience init(queue: Queue = playerSyncQueue, timeline: Timeline?, formats: [Format] = []) throws {
        try self.init(
            queue: queue,
            timeline: timeline,
            trackGroupArray: Self.buildTrackGroupArray(formats: formats)
        )
    }

    init(
        queue: Queue,
        timeline: Timeline? = nil,
        trackDataFactory: FakeMediaPeriod.TrackDataFactory? = nil,
        syncSampleTimesUs: [Int64]? = nil,
        trackGroupArray: TrackGroupArray
    ) {
        self.queue = queue
        self.trackGroupArray = trackGroupArray
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
        guard let timeline, !timeline.isEmpty else {
            return Self.fakeMediaItem
        }

        return timeline.getWindow(windowIndex: 0, window: Window()).mediaItem
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
        timeline.getPeriod(periodIndex: periodIndex, period: Period())
        let mediaPeriod = try createMediaPeriod(
            id: id,
            trackGroups: trackGroupArray,
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

    func setNewSourceInfo(
        newTimeline: Timeline,
        sendManifestLoadEvents: Bool = true,
        isolation: isolated (any Actor)? = #isolation
    ) throws {
        assert(queue.isCurrent())
        #expect(preparationAllowed)
        if preparedSource {
            #expect(!releasedSource)
            timeline = newTimeline
            try! self.finishSourcePreparation(sendManifestLoadEvents: sendManifestLoadEvents)
        } else {
            timeline = newTimeline
        }
    }

    func createMediaPeriod(
        id: MediaPeriodId,
        trackGroups: TrackGroupArray,
        allocator: Allocator,
        transferListener: TransferListener?
    ) throws -> FakeMediaPeriod {
        let timeline = try #require(timeline)
        let positionInWindowUs = timeline.periodById(id.periodId, period: Period()).positionInWindowUs
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
        print("❌ finishSourcePreparation")
        try refreshSourceInfo(timeline: #require(timeline))
    }
}

extension FakeMediaSource {
    final class InitialTimeline: ForwardingTimeline, @unchecked Sendable {
        override func getWindow(windowIndex: Int, window: Window, defaultPositionProjectionUs: Int64) -> Window {
            let childWindow = timeline.getWindow(
                windowIndex: windowIndex,
                window: window,
                defaultPositionProjectionUs: defaultPositionProjectionUs
            )
            childWindow.isDynamic = true
            childWindow.isSeekable = false
            return childWindow
        }
    }

    static func buildTrackGroupArray(formats: [Format]) throws -> TrackGroupArray {
        TrackGroupArray(trackGroups: try formats.map { try TrackGroup(formats: [$0]) })
    }
}

extension FakeMediaSource {
    static let fakeMediaItem = MediaItem.Builder()
        .setMediaId("FakeMediaSource")
        .setUrl(URL(string: "http://manifest.url")!)
        .build()
}
