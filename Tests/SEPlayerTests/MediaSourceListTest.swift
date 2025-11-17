//
//  MediaSourceListTest.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Foundation
import Testing
@testable import SEPlayer

@TestableSyncPlayerActor
struct MediaSourceListTest {
    private let mediaSourceListSize = 4
    private let minimalMediaItem = MediaItem.Builder().setMediaId("").build()
    private let mediaSourceList: MediaSourceList

    init() {
        mediaSourceList = MediaSourceList(playerId: UUID())
    }

    @Test
    func emptyMediaSourceListExpectConstantTimelineInstanceEmpty() throws {
        let shuffleOrder = DefaultShuffleOrder(length: 0)
        let fakeHolders = try createFakeHolders()
        var timeline = try mediaSourceList.setMediaSource(
            holders: fakeHolders,
            shuffleOrder: shuffleOrder
        )
        #expect(!timeline.equals(to: emptyTimeline))

        timeline = mediaSourceList.removeMediaSource(
            range: 0..<timeline.windowCount(),
            shuffleOrder: shuffleOrder
        )
        #expect(timeline.equals(to: emptyTimeline))

        timeline = try mediaSourceList.setMediaSource(
            holders: fakeHolders,
            shuffleOrder: shuffleOrder
        )
        #expect(!timeline.equals(to: emptyTimeline))

        timeline = mediaSourceList.clear(shuffleOrder: shuffleOrder)
        #expect(timeline.equals(to: emptyTimeline))
    }

    @Test
    func prepareAndReprepareAfterReleaseExpectSourcePreparationAfterMediaSourceListPrepare() throws {
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)

        _ = try mediaSourceList.setMediaSource(
            holders: createFakeHoldersWithSources(
                [mockMediaSource1, mockMediaSource2],
                useLazyPreparation: false
            ),
            shuffleOrder: DefaultShuffleOrder(length: 2)
        )

        // Verify prepare is called once on prepare.
        let functionName = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource1.methodInvocationStorage[functionName] == nil)
        #expect(mockMediaSource2.methodInvocationStorage[functionName] == nil)

        try mediaSourceList.prepare(mediaTransferListener: nil)
        #expect(mediaSourceList.isPrepared)
        // Verify prepare is called once on prepare.
        #expect(mockMediaSource1.methodInvocationStorage[functionName] == 1)
        #expect(mockMediaSource2.methodInvocationStorage[functionName] == 1)

        mediaSourceList.release()
        try mediaSourceList.prepare(mediaTransferListener: nil)
        // Verify prepare is called a second time on re-prepare.
        #expect(mockMediaSource1.methodInvocationStorage[functionName] == 2)
        #expect(mockMediaSource2.methodInvocationStorage[functionName] == 2)
    }

    @Test
    func setMediaSourcesMediaSourceListUnpreparedNotUsingLazyPreparation() throws {
        let shuffleOrder = DefaultShuffleOrder(length: 2)
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mediaSources = createFakeHoldersWithSources(
            [mockMediaSource1, mockMediaSource2],
            useLazyPreparation: false
        )
        var timeline = try mediaSourceList.setMediaSource(holders: mediaSources, shuffleOrder: shuffleOrder)
        #expect(timeline.windowCount() == 2)
        #expect(mediaSourceList.getSize() == 2)

        // Assert holder offsets have been set properly
        for (index, mediaSourceHolder) in mediaSources.enumerated() {
            #expect(!mediaSourceHolder.isRemoved)
            #expect(mediaSourceHolder.firstWindowIndexInChild == index)
        }

        // Set media items again. The second holder is re-used.
        let mockMediaSource3 = MediaSourceMock(mediaItem: minimalMediaItem)
        var moreMediaSources = createFakeHoldersWithSources([mockMediaSource3], useLazyPreparation: false)
        moreMediaSources.append(mediaSources[1])

        timeline = try mediaSourceList.setMediaSource(holders: moreMediaSources, shuffleOrder: shuffleOrder)
        #expect(mediaSourceList.getSize() == 2)
        #expect(timeline.windowCount() == 2)
        // Assert holder offsets have been set properly
        for (index, mediaSourceHolder) in moreMediaSources.enumerated() {
            #expect(!mediaSourceHolder.isRemoved)
            #expect(mediaSourceHolder.firstWindowIndexInChild == index)
        }

        let functionName = "releaseSource(delegate:)"
        // Expect removed holders and sources to be removed without releasing.
        #expect(mockMediaSource1.methodInvocationStorage[functionName] == nil)
        #expect(mediaSources[0].isRemoved)
        // Expect re-used holder and source not to be removed.
        #expect(mockMediaSource2.methodInvocationStorage[functionName] == nil)
        #expect(!mediaSources[1].isRemoved)
    }

    @Test
    func setMediaSourcesMediaSourceListPreparedNotUsingLazyPreparation() throws {
        let shuffleOrder = DefaultShuffleOrder(length: 2)
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mediaSources = createFakeHoldersWithSources(
            [mockMediaSource1, mockMediaSource2],
            useLazyPreparation: false
        )

        try mediaSourceList.prepare(mediaTransferListener: nil)
        _ = try mediaSourceList.setMediaSource(holders: mediaSources, shuffleOrder: shuffleOrder)

        // Verify sources are prepared.
        let prepareFn = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource1.methodInvocationStorage[prepareFn] == 1)
        #expect(mockMediaSource2.methodInvocationStorage[prepareFn] == 1)

        // Set media items again. The second holder is re-used.
        let mockMediaSource3 = MediaSourceMock(mediaItem: minimalMediaItem)
        var moreMediaSources = createFakeHoldersWithSources([mockMediaSource3], useLazyPreparation: false)
        moreMediaSources.append(mediaSources[1])
        _ = try mediaSourceList.setMediaSource(holders: moreMediaSources, shuffleOrder: shuffleOrder)

        let releaseFn = "releaseSource(delegate:)"

        // Expect removed holders and sources to be removed and released.
        #expect(mockMediaSource1.methodInvocationStorage[releaseFn] == 1)
        #expect(mediaSources[0].isRemoved)

        // Expect re-used holder and source not to be removed but released.
        #expect(mockMediaSource2.methodInvocationStorage[releaseFn] == 1)
        #expect(!mediaSources[1].isRemoved)
        #expect(mockMediaSource2.methodInvocationStorage[prepareFn] == 2)
    }

    @Test
    func addMediaSourcesMediaSourceListUnpreparedNotUsingLazyPreparationExpectUnprepared() throws {
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mediaSources = createFakeHoldersWithSources(
            [mockMediaSource1, mockMediaSource2],
            useLazyPreparation: false
        )
        _ = try mediaSourceList.addMediaSource(
            index: 0,
            holders: mediaSources,
            shuffleOrder: DefaultShuffleOrder(length: 2)
        )

        #expect(mediaSourceList.getSize() == 2)
        // Verify lazy initialization does not call prepare on sources.
        let prepareFn = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource1.methodInvocationStorage[prepareFn] == nil)
        #expect(mockMediaSource2.methodInvocationStorage[prepareFn] == nil)

        for (i, holder) in mediaSources.enumerated() {
            #expect(holder.firstWindowIndexInChild == i)
            #expect(!holder.isRemoved)
        }

        // Add for more sources in between.
        let moreMediaSources = try createFakeHolders()
        _ = try mediaSourceList.addMediaSource(
            index: 1,
            holders: moreMediaSources,
            shuffleOrder: DefaultShuffleOrder(length: 3)
        )

        #expect(mediaSources[0].firstWindowIndexInChild == 0)
        #expect(moreMediaSources[0].firstWindowIndexInChild == 1)
        #expect(moreMediaSources[3].firstWindowIndexInChild == 4)
        #expect(mediaSources[1].firstWindowIndexInChild == 5)
    }

    @Test
    func addMediaSourcesMediaSourceListPreparedNotUsingLazyPreparationExpectPrepared() throws {
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        try mediaSourceList.prepare(mediaTransferListener: nil)
        _ = try mediaSourceList.addMediaSource(
            index: 0,
            holders: createFakeHoldersWithSources([mockMediaSource1, mockMediaSource2], useLazyPreparation: false),
            shuffleOrder: DefaultShuffleOrder(length: 2)
        )

        // Verify prepare is called on sources when added.
        let prepareFn = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource1.methodInvocationStorage[prepareFn] == 1)
        #expect(mockMediaSource2.methodInvocationStorage[prepareFn] == 1)
    }

    @Test
    func moveMediaSources() throws {
        let shuffleOrder = DefaultShuffleOrder(length: 4)
        let holders = try createFakeHolders()
        _ = try mediaSourceList.addMediaSource(index: 0, holders: holders, shuffleOrder: shuffleOrder)

        assertDefaultFirstWindowInChildIndexOrder(holders: holders)
        _ = mediaSourceList.moveMediaSource(from: 0, to: 3, shuffleOrder: shuffleOrder)
        assertFirstWindowInChildIndices(holders: holders, firstWindowInChildIndices: [3, 0, 1, 2])
        _ = mediaSourceList.moveMediaSource(from: 3, to: 0, shuffleOrder: shuffleOrder)
        assertDefaultFirstWindowInChildIndexOrder(holders: holders)

        _ = mediaSourceList.moveMediaSourceRange(range: 0..<2, to: 2, shuffleOrder: shuffleOrder)
        assertFirstWindowInChildIndices(holders: holders, firstWindowInChildIndices: [2, 3, 0, 1])
        _ = mediaSourceList.moveMediaSourceRange(range: 2..<4, to: 0, shuffleOrder: shuffleOrder)
        assertDefaultFirstWindowInChildIndexOrder(holders: holders)

        _ = mediaSourceList.moveMediaSourceRange(range: 0..<2, to: 2, shuffleOrder: shuffleOrder)
        assertFirstWindowInChildIndices(holders: holders, firstWindowInChildIndices: [2, 3, 0, 1])
        _ = mediaSourceList.moveMediaSourceRange(range: 2..<3, to: 0, shuffleOrder: shuffleOrder)
        assertFirstWindowInChildIndices(holders: holders, firstWindowInChildIndices: [0, 3, 1, 2])
        _ = mediaSourceList.moveMediaSourceRange(range: 3..<4, to: 1, shuffleOrder: shuffleOrder)
        assertDefaultFirstWindowInChildIndexOrder(holders: holders)

        // No-ops.
        _ = mediaSourceList.moveMediaSourceRange(range: 0..<4, to: 0, shuffleOrder: shuffleOrder)
        assertDefaultFirstWindowInChildIndexOrder(holders: holders)
        _ = mediaSourceList.moveMediaSourceRange(range: 0..<0, to: 3, shuffleOrder: shuffleOrder)
        assertDefaultFirstWindowInChildIndexOrder(holders: holders)
    }

    @Test
    func removeMediaSourcesWhenUnpreparedExpectNoRelease() throws {
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource3 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource4 = MediaSourceMock(mediaItem: minimalMediaItem)
        let shuffleOrder = DefaultShuffleOrder(length: 4)

        var holders = createFakeHoldersWithSources(
            [mockMediaSource1, mockMediaSource2, mockMediaSource3, mockMediaSource4],
            useLazyPreparation: false
        )
        _ = try mediaSourceList.addMediaSource(index: 0, holders: holders, shuffleOrder: shuffleOrder)
        _ = mediaSourceList.removeMediaSource(range: 1..<3, shuffleOrder: shuffleOrder)

        #expect(mediaSourceList.getSize() == 2)
        let removedHolder1 = holders.remove(at: 1)
        let removedHolder2 = holders.remove(at: 1)

        assertDefaultFirstWindowInChildIndexOrder(holders: holders)
        #expect(removedHolder1.isRemoved)
        #expect(removedHolder2.isRemoved)
        let releaseFn = "releaseSource(delegate:)"
        #expect(mockMediaSource1.methodInvocationStorage[releaseFn] == nil)
        #expect(mockMediaSource2.methodInvocationStorage[releaseFn] == nil)
        #expect(mockMediaSource3.methodInvocationStorage[releaseFn] == nil)
        #expect(mockMediaSource4.methodInvocationStorage[releaseFn] == nil)
    }

    @Test
    func removeMediaSourcesWhenPreparedExpectRelease() throws {
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource3 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource4 = MediaSourceMock(mediaItem: minimalMediaItem)
        let shuffleOrder = DefaultShuffleOrder(length: 4)

        var holders = createFakeHoldersWithSources(
            [mockMediaSource1, mockMediaSource2, mockMediaSource3, mockMediaSource4],
            useLazyPreparation: false
        )
        try mediaSourceList.prepare(mediaTransferListener: nil)
        _ = try mediaSourceList.addMediaSource(index: 0, holders: holders, shuffleOrder: shuffleOrder)
        _ = mediaSourceList.removeMediaSource(range: 1..<3, shuffleOrder: shuffleOrder)

        #expect(mediaSourceList.getSize() == 2)
        holders.remove(at: 2)
        holders.remove(at: 1)

        assertDefaultFirstWindowInChildIndexOrder(holders: holders)
        let releaseFn = "releaseSource(delegate:)"
        #expect(mockMediaSource1.methodInvocationStorage[releaseFn] == nil)
        #expect(mockMediaSource2.methodInvocationStorage[releaseFn] == 1)
        #expect(mockMediaSource3.methodInvocationStorage[releaseFn] == 1)
        #expect(mockMediaSource4.methodInvocationStorage[releaseFn] == nil)
    }

    @Test
    func releaseMediaSourceListUnpreparedExpectSourcesNotReleased() throws {
        let mockMediaSource = MediaSourceMock(mediaItem: minimalMediaItem)
        let holders = createFakeHoldersWithSources([mockMediaSource], useLazyPreparation: false)

        _ = try mediaSourceList.setMediaSource(
            holders: holders,
            shuffleOrder: DefaultShuffleOrder(length: 1)
        )
        let prepareFn = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource.methodInvocationStorage[prepareFn] == nil)

        mediaSourceList.release()
        let releaseFn = "releaseSource(delegate:)"
        #expect(mockMediaSource.methodInvocationStorage[releaseFn] == nil)
        #expect(holders[0].isRemoved == false)
    }

    @Test
    func releaseMediaSourceListPreparedExpectSourcesReleasedNotRemoved() throws {
        let mockMediaSource = MediaSourceMock(mediaItem: minimalMediaItem)
        let holders = createFakeHoldersWithSources([mockMediaSource], useLazyPreparation: false)

        try mediaSourceList.prepare(mediaTransferListener: nil)
        _ = try mediaSourceList.setMediaSource(
            holders: holders,
            shuffleOrder: DefaultShuffleOrder(length: 1)
        )
        let prepareFn = "prepareSource(delegate:mediaTransferListener:playerId:)"
        #expect(mockMediaSource.methodInvocationStorage[prepareFn] == 1)

        mediaSourceList.release()
        let releaseFn = "releaseSource(delegate:)"
        #expect(mockMediaSource.methodInvocationStorage[releaseFn] == 1)
        #expect(holders[0].isRemoved == false)
    }

    @Test
    func clearMediaSourceListExpectSourcesReleasedAndRemoved() throws {
        let shuffleOrder = DefaultShuffleOrder(length: 4)
        let mockMediaSource1 = MediaSourceMock(mediaItem: minimalMediaItem)
        let mockMediaSource2 = MediaSourceMock(mediaItem: minimalMediaItem)
        let holders = createFakeHoldersWithSources([mockMediaSource1, mockMediaSource2], useLazyPreparation: false)
        _ = try mediaSourceList.setMediaSource(holders: holders, shuffleOrder: shuffleOrder)
        try mediaSourceList.prepare(mediaTransferListener: nil)

        let timeline = mediaSourceList.clear(shuffleOrder: shuffleOrder)
        #expect(timeline.isEmpty)

        #expect(holders[0].isRemoved)
        #expect(holders[1].isRemoved)

        let releaseFn = "releaseSource(delegate:)"
        #expect(mockMediaSource1.methodInvocationStorage[releaseFn] == 1)
        #expect(mockMediaSource2.methodInvocationStorage[releaseFn] == 1)
    }

    @Test
    func setMediaSourcesExpectTimelineUsesCustomShuffleOrder() throws {
        let timeline = try mediaSourceList.setMediaSource(
            holders: createFakeHolders(),
            shuffleOrder: FakeShuffleOrder(count: 4)
        )
        assertTimelineUsesFakeShuffleOrder(timeline: timeline)
    }

    @Test
    func addMediaSourcesExpectTimelineUsesCustomShuffleOrder() throws {
        let timeline = try mediaSourceList.addMediaSource(
            index: 0,
            holders: try createFakeHolders(),
            shuffleOrder: FakeShuffleOrder(count: mediaSourceListSize)
        )
        assertTimelineUsesFakeShuffleOrder(timeline: timeline)
    }

    @Test
    func moveMediaSourcesExpectTimelineUsesCustomShuffleOrder() throws {
        let shuffleOrder = DefaultShuffleOrder(length: mediaSourceListSize)
        _ = try mediaSourceList.addMediaSource(index: 0, holders: try createFakeHolders(), shuffleOrder: shuffleOrder)
        let timeline = mediaSourceList.moveMediaSource(from: 0, to: 1, shuffleOrder: FakeShuffleOrder(count: mediaSourceListSize))
        assertTimelineUsesFakeShuffleOrder(timeline: timeline)
    }

    @Test
    func moveMediaSourceRangeExpectTimelineUsesCustomShuffleOrder() throws {
        let shuffleOrder = DefaultShuffleOrder(length: mediaSourceListSize)
        _ = try mediaSourceList.addMediaSource(index: 0, holders: try createFakeHolders(), shuffleOrder: shuffleOrder)
        let timeline = mediaSourceList.moveMediaSourceRange(
            range: 0..<2,
            to: 2,
            shuffleOrder: FakeShuffleOrder(count: mediaSourceListSize)
        )
        assertTimelineUsesFakeShuffleOrder(timeline: timeline)
    }

    @Test
    func removeMediaSourceRangeExpectTimelineUsesCustomShuffleOrder() throws {
        let shuffleOrder = DefaultShuffleOrder(length: mediaSourceListSize)
        _ = try mediaSourceList.addMediaSource(index: 0, holders: try createFakeHolders(), shuffleOrder: shuffleOrder)
        let timeline = mediaSourceList.removeMediaSource(range: 0..<2, shuffleOrder: FakeShuffleOrder(count: 2))
        assertTimelineUsesFakeShuffleOrder(timeline: timeline)
    }

    @Test
    func setShuffleOrderExpectTimelineUsesCustomShuffleOrder() throws {
        _ = try mediaSourceList.setMediaSource(
            holders: try createFakeHolders(),
            shuffleOrder: DefaultShuffleOrder(length: mediaSourceListSize)
        )
        assertTimelineUsesFakeShuffleOrder(
            timeline: mediaSourceList.setShuffleOrder(new: FakeShuffleOrder(count: mediaSourceListSize))
        )
    }

    @Test
    func updateMediaSourcesWithMediaItemsUpdatesMediaItemsForPreparedAndPlaceholderSources() throws {
        let unaffectedSource = try FakeMediaSource(syncQueue: playerSyncQueue)
        let preparedSource = try FakeMediaSource(syncQueue: playerSyncQueue)
        preparedSource.setCanUpdateMediaItems(true)
        try preparedSource.setAllowPreparation(true)
        let unpreparedSource = try FakeMediaSource(syncQueue: playerSyncQueue)
        unpreparedSource.setCanUpdateMediaItems(true)
        try unpreparedSource.setAllowPreparation(false)
        _ = try mediaSourceList.setMediaSource(
            holders: createFakeHoldersWithSources(
                [unaffectedSource, preparedSource, unpreparedSource],
                useLazyPreparation: false
            ),
            shuffleOrder: DefaultShuffleOrder(length: 3)
        )
        try mediaSourceList.prepare(mediaTransferListener: nil)
        let unaffectedMediaItem = unaffectedSource.getMediaItem()
        let updatedItem1 = MediaItem.Builder().setMediaId("1").build()
        let updatedItem2 = MediaItem.Builder().setMediaId("2").build()

        let timeline = try mediaSourceList.updateMediaSources(
            with: [updatedItem1, updatedItem2],
            range: 1..<3
        )

        #expect({
            var window = Window()
            return timeline.getWindow(windowIndex: 0, window: &window).mediaItem == unaffectedMediaItem
        }())
        #expect({
            var window = Window()
            return timeline.getWindow(windowIndex: 1, window: &window).mediaItem == updatedItem1
        }())
        #expect({
            var window = Window()
            return timeline.getWindow(windowIndex: 1, window: &window).isPlaceholder == false
        }())
        #expect({
            var window = Window()
            return timeline.getWindow(windowIndex: 2, window: &window).mediaItem == updatedItem2
        }())
        #expect({
            var window = Window()
            return timeline.getWindow(windowIndex: 2, window: &window).isPlaceholder == true
        }())
    }

    private func assertTimelineUsesFakeShuffleOrder(timeline: Timeline) {
        #expect(
            timeline.nextWindowIndex(
                windowIndex: 0,
                repeatMode: .off,
                shuffleModeEnabled: true
            ) == nil
        )
        #expect(
            timeline.previousWindowIndex(
                windowIndex: timeline.windowCount() - 1,
                repeatMode: .off,
                shuffleModeEnabled: true
            ) == nil
        )
    }

    private func assertDefaultFirstWindowInChildIndexOrder(holders: [MediaSourceList.MediaSourceHolder]) {
        assertFirstWindowInChildIndices(
            holders: holders,
            firstWindowInChildIndices: holders.indices.map { $0 }
        )
    }

    private func assertFirstWindowInChildIndices(
        holders: [MediaSourceList.MediaSourceHolder],
        firstWindowInChildIndices: [Int]
    ) {
        #expect(holders.count == firstWindowInChildIndices.count)
        for (holder, index) in zip(holders, firstWindowInChildIndices) {
            #expect(holder.firstWindowIndexInChild == index)
        }
    }

    private func createFakeHolders() throws -> [MediaSourceList.MediaSourceHolder] {
        try (0..<mediaSourceListSize).map { _ in
            try MediaSourceList.MediaSourceHolder(
                queue: playerSyncQueue,
                mediaSource: FakeMediaSource(syncQueue: playerSyncQueue),
                useLazyPreparation: true
            )
        }
    }

    private func createFakeHoldersWithSources(_ sources: [MediaSource], useLazyPreparation: Bool) -> [MediaSourceList.MediaSourceHolder] {
        sources.map {
            MediaSourceList.MediaSourceHolder(
                queue: playerSyncQueue,
                mediaSource: $0,
                useLazyPreparation: useLazyPreparation
            )
        }
    }
}
