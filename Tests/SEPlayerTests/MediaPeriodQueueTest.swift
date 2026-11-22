//
//  MediaPeriodQueueTest.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.MediaPeriodQueueTest
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
@testable import SEPlayer
@testable import SEPlayerCommon
import Testing

@TestableSyncPlayerActor
class MediaPeriodQueueTest {
    private let playerId = UUID()
    private let contentDurationUs = 30 * Int64.microsecondsPerSecond
    private let adDurationUs = 10 * Int64.microsecondsPerSecond
    private let firstAdStartTimeUs = 10 * Int64.microsecondsPerSecond
    private let secondAdStartTimeUs = 20 * Int64.microsecondsPerSecond

    private let adMediaItem = MediaItem.Builder().setUrl(URL(string: "example.com")!).build()
    private lazy var contentTimeline = SinglePeriodTimeline(
        duration: .time(us: contentDurationUs),
        isSeekable: true,
        isDynamic: false,
        useLiveConfiguration: false,
        manifest: nil,
        mediaItem: adMediaItem
    )

    private let mediaPeriodQueue: MediaPeriodQueue
    private var addPlaybackState: AdPlaybackState = .none
    private var firstPeriodId: AnyHashable = 0
    private var playbackInfo: PlaybackInfo?
    private var rendererCapabilities: [RendererCapabilitiesResolver]
    private let trackSelector: TrackSelector
    private let bufferedBytesCounter: BufferedBytesCounter
    private let mediaSourceList: MediaSourceList
    private var fakeMediaSources: [FakeMediaSource]
    private var mediaPeriodHolderFactoryInfos: [MediaPeriodInfo] = []
    private var mediaPeriodHolderFactoryRendererPositionOffsets: [CMTime] = []

    init() {
        mediaSourceList = MediaSourceList(playerId: playerId)
        rendererCapabilities = []
        trackSelector = DefaultTrackSelector()
        bufferedBytesCounter = DefaultBufferedBytesCounter()
        fakeMediaSources = []

        mediaPeriodQueue = MediaPeriodQueue(preloadConfiguration: .default)
        mediaPeriodQueue.setMediaPeriodBuilder { [weak self] info, rendererPositionOffset in
            guard let self else { throw ErrorBuilder.illegalState() }
            TestableSyncPlayerActor.shared.assertIsolated()

            mediaPeriodHolderFactoryInfos.append(info)
            mediaPeriodHolderFactoryRendererPositionOffsets.append(rendererPositionOffset)

            return try MediaPeriodHolder(
                queue: playerSyncQueue,
                rendererCapabilities: rendererCapabilities,
                rendererPositionOffset: rendererPositionOffset,
                trackSelector: trackSelector,
                bufferedBytesCounter: bufferedBytesCounter,
                mediaSourceList: mediaSourceList,
                info: info,
                emptyTrackSelectorResult: TrackSelectorResult(
                    rendererConfigurations: [],
                    selections: [],
                    tracks: .empty
                ),
                targetPreloadBufferDuration: .time(us: 5_000_000)
            )
        }
    }

    @Test
    func getNextMediaPeriodInfoWithoutAdsReturnsLastMediaPeriodInfo() throws {
        try setupAdTimeline()
        try assertGetNextMediaPeriodInfoReturnsContentMediaPeriod(
            periodId: firstPeriodId,
            startPositionUs: 0,
            requestedContentPositionUs: .timeUnset,
            endPositionUs: .timeUnset,
            durationUs: contentDurationUs,
            isPrecededByTransitionFromSameStream: false,
            isFollowedByTransitionToSameStream: false,
            isLastInPeriod: true,
            isLastInWindow: true,
            isFinal: true,
            nextAdGroupIndex: nil
        )
    }

    @Test
    func `getNextMediaPeriodInfo inMultiPeriodWindow returnsCorrectMediaPeriodInfos`() throws {
        try setupTimelines([
            FakeTimeline(
                windowDefinitions: [
                    .init(
                        periodCount: 2,
                        id: UUID(),
                        isSeekable: false,
                        isDynamic: false,
                        durationUs: 2 * contentDurationUs
                    ),
                ]
            ),
        ])

        try assertGetNextMediaPeriodInfoReturnsContentMediaPeriod(
            periodId: playbackInfo?.timeline.id(for: 0) ?? AnyHashable(UUID()),
            startPositionUs: 0,
            requestedContentPositionUs: .timeUnset,
            endPositionUs: .timeUnset,
            durationUs: contentDurationUs + FakeTimeline.TimelineWindowDefinition.defaultWindowOffsetInFirstPeriodUs,
            isPrecededByTransitionFromSameStream: false,
            isFollowedByTransitionToSameStream: false,
            isLastInPeriod: true,
            isLastInWindow: false,
            isFinal: false,
            nextAdGroupIndex: nil
        )

        try advance()

        try assertGetNextMediaPeriodInfoReturnsContentMediaPeriod(
            periodId: playbackInfo?.timeline.id(for: 1) ?? AnyHashable(UUID()),
            startPositionUs: 0,
            requestedContentPositionUs: 0,
            endPositionUs: .timeUnset,
            durationUs: contentDurationUs,
            isPrecededByTransitionFromSameStream: false,
            isFollowedByTransitionToSameStream: false,
            isLastInPeriod: true,
            isLastInWindow: true,
            isFinal: true,
            nextAdGroupIndex: nil
        )
    }

    @Test
    func `invalidatePreloadPool withThreeWindowsPreloadEnabled preloadHoldersCreated`() throws {
        try setupTimelines([FakeTimeline(), FakeTimeline(), FakeTimeline()])
        let playbackInfo = try #require(playbackInfo)
        try mediaPeriodQueue.updatePreloadConfiguration(
            new: PreloadConfiguration(targetPreloadDuration: .time(us: 5_000_000)),
            timeline: playbackInfo.timeline
        )

        // Creates period of first window for enqueuing.
        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 1)
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.first?.microseconds == 1_000_000_000_000)
        #expect(mediaPeriodHolderFactoryInfos[0].id.periodId == playbackInfo.timeline.id(for: 0))
        #expect(mediaPeriodHolderFactoryInfos[0].id.windowSequenceNumber == 0)

        // Creates period of second window for preloading.
        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)
        #expect(mediaPeriodHolderFactoryInfos.count == 2)
        #expect({
            let first = mediaPeriodHolderFactoryRendererPositionOffsets[0].microseconds
            let second = mediaPeriodHolderFactoryRendererPositionOffsets[1].microseconds
            return first == 1_000_000_000_000 && second == 1_000_010_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[1].id.periodId == playbackInfo.timeline.id(for: 1))
        #expect(mediaPeriodHolderFactoryInfos[1].id.windowSequenceNumber == 1)

        // Enqueue period of second window from preload pool.
        try enqueueNext()
        #expect(mediaPeriodHolderFactoryInfos.count == 2)

        // Creates period of third window for preloading.
        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)
        #expect(mediaPeriodHolderFactoryInfos.count == 3)
        #expect({
            let first = mediaPeriodHolderFactoryRendererPositionOffsets[0].microseconds
            let second = mediaPeriodHolderFactoryRendererPositionOffsets[1].microseconds
            let third = mediaPeriodHolderFactoryRendererPositionOffsets[2].microseconds
            return first == 1_000_000_000_000 &&
                second == 1_000_010_000_000 &&
                third == 1_000_020_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[2].id.periodId == playbackInfo.timeline.id(for: 2))
        #expect(mediaPeriodHolderFactoryInfos[2].id.windowSequenceNumber == 2)

        // Enqueue period of third window from preload pool.
        try enqueueNext()
        // No further next window. Invalidating is a no-op.
        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 3)
    }

    @Test
    func `invalidatePreloadPool withThreeWindowsPreloadDisabled preloadHoldersNotCreated`() throws {
        var releasedMediaPeriods: [MediaPeriod] = []

        final class RecordingFakeMediaSource: FakeMediaSource {
            private let onRelease: (MediaPeriod) -> Void

            init(queue: Queue, onRelease: @escaping (MediaPeriod) -> Void) throws {
                self.onRelease = onRelease
                try super.init(
                    queue: queue,
                    timeline: FakeTimeline(),
                    trackGroupArray: FakeMediaSource.buildTrackGroupArray(formats: [])
                )
            }

            override func release(mediaPeriod: MediaPeriod) {
                onRelease(mediaPeriod)
                super.release(mediaPeriod: mediaPeriod)
            }
        }

        let fakeMediaSource = try RecordingFakeMediaSource(queue: playerSyncQueue) { mediaPeriod in
            releasedMediaPeriods.append(mediaPeriod)
        }

        try setupMediaSources([fakeMediaSource, fakeMediaSource, fakeMediaSource])
        let playbackInfo = try #require(playbackInfo)
        try mediaPeriodQueue.updatePreloadConfiguration(
            new: .default,
            timeline: playbackInfo.timeline
        )

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 1)
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.first?.microseconds == 1_000_000_000_000)
        #expect(mediaPeriodHolderFactoryInfos[0].id.periodId == playbackInfo.timeline.id(for: 0))
        #expect(mediaPeriodHolderFactoryInfos[0].id.windowSequenceNumber == 0)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 1)

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 2)
        #expect({
            let first = mediaPeriodHolderFactoryRendererPositionOffsets[0].microseconds
            let second = mediaPeriodHolderFactoryRendererPositionOffsets[1].microseconds
            return first == 1_000_000_000_000 && second == 1_000_010_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[1].id.periodId == playbackInfo.timeline.id(for: 1))
        #expect(mediaPeriodHolderFactoryInfos[1].id.windowSequenceNumber == 1)
        #expect(releasedMediaPeriods.isEmpty)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 2)

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 3)
        #expect({
            let first = mediaPeriodHolderFactoryRendererPositionOffsets[0].microseconds
            let second = mediaPeriodHolderFactoryRendererPositionOffsets[1].microseconds
            let third = mediaPeriodHolderFactoryRendererPositionOffsets[2].microseconds
            return first == 1_000_000_000_000 &&
                second == 1_000_010_000_000 &&
                third == 1_000_020_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[2].id.periodId == playbackInfo.timeline.id(for: 2))
        #expect(mediaPeriodHolderFactoryInfos[2].id.windowSequenceNumber == 2)
        #expect(releasedMediaPeriods.isEmpty)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 3)
    }

    @Test
    func `invalidatePreloadPool secondWindowIsLivePreloadEnabled preloadHolderForLiveNotCreated`() throws {
        let liveWindow = FakeTimeline.TimelineWindowDefinition(
            periodCount: 1,
            id: 1234,
            isSeekable: false,
            isDynamic: true,
            isLive: true,
            isPlaceholder: false,
            durationUs: FakeTimeline.TimelineWindowDefinition.defaultWindowDurationUs,
            defaultPositionUs: 0,
            windowOffsetInFirstPeriodUs: FakeTimeline.TimelineWindowDefinition.defaultWindowOffsetInFirstPeriodUs,
            adPlaybackStates: [AdPlaybackState.none],
            mediaItem: MediaItem.empty
        )

        try setupTimelines([FakeTimeline(), FakeTimeline(windowDefinitions: [liveWindow])])
        let playbackInfo = try #require(playbackInfo)

        try mediaPeriodQueue.updatePreloadConfiguration(
            new: PreloadConfiguration(targetPreloadDuration: .time(us: 5_000_000)),
            timeline: playbackInfo.timeline
        )

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 1)
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.first?.microseconds == 1_000_000_000_000)
        #expect(mediaPeriodHolderFactoryInfos[0].id.periodId == playbackInfo.timeline.id(for: 0))
        #expect(mediaPeriodHolderFactoryInfos[0].id.windowSequenceNumber == 0)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        withKnownIssue("Expected to be a no-op for live, but live is not supported") {
            #expect(mediaPeriodHolderFactoryInfos.count == 1)
        }

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 2)
        #expect({
            let offsets = mediaPeriodHolderFactoryRendererPositionOffsets
            let first = offsets[0].microseconds
            let second = offsets[1].microseconds
            return first == 1_000_000_000_000 && second == 1_000_010_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[1].id.periodId == playbackInfo.timeline.id(for: 1))
        #expect(mediaPeriodHolderFactoryInfos[1].id.windowSequenceNumber == 1)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 2)
    }

    @Test
    func `invalidatePreloadPool windowWithTwoPeriodsPreloadEnabled preloadHolderForThirdPeriodCreated`() throws {
        let window1 = FakeTimeline.TimelineWindowDefinition(
            periodCount: 2,
            id: 1234
        )

        try setupTimelines([FakeTimeline(windowDefinitions: [window1]), FakeTimeline()])
        let playbackInfo = try #require(playbackInfo)

        try mediaPeriodQueue.updatePreloadConfiguration(
            new: PreloadConfiguration(targetPreloadDuration: .time(us: 5_000_000)),
            timeline: playbackInfo.timeline
        )

        try enqueueNext()

        #expect(mediaPeriodHolderFactoryInfos.count == 1)
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.first?.microseconds == 1_000_000_000_000)
        #expect(mediaPeriodHolderFactoryInfos[0].id.periodId ==
            playbackInfo.timeline.id(for: 0))
        #expect(mediaPeriodHolderFactoryInfos[0].id.windowSequenceNumber == 0)

        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect(mediaPeriodHolderFactoryInfos.count == 2)
        #expect({
            let offsets = mediaPeriodHolderFactoryRendererPositionOffsets
            let first = offsets[0].microseconds
            let second = offsets[1].microseconds
            return first == 1_000_000_000_000 &&
                second == 1_000_005_000_000
        }())
        #expect(mediaPeriodHolderFactoryInfos[1].id.periodId ==
            playbackInfo.timeline.id(for: 2))
        #expect(mediaPeriodHolderFactoryInfos[1].id.windowSequenceNumber == 1)
    }

    @Test
    func `setPreloadConfiguration disablePreloading releasesPreloadHolders`() throws {
        var releaseCalled = false

        final class RecordingFakeMediaSource: FakeMediaSource {
            private let onRelease: (MediaPeriod) -> Void

            init(queue: Queue, timeline: FakeTimeline, onRelease: @escaping (MediaPeriod) -> Void) throws {
                self.onRelease = onRelease
                try super.init(
                    queue: queue,
                    timeline: timeline,
                    trackGroupArray: FakeMediaSource.buildTrackGroupArray(formats: [])
                )
            }

            override func release(mediaPeriod: MediaPeriod) {
                onRelease(mediaPeriod)
                super.release(mediaPeriod: mediaPeriod)
            }
        }

        let preloadedTimeline = FakeTimeline(
            windowDefinitions: [
                FakeTimeline.TimelineWindowDefinition(
                    periodCount: 1,
                    id: "1234"
                ),
            ]
        )

        let preloadedSource = try RecordingFakeMediaSource(
            queue: playerSyncQueue,
            timeline: preloadedTimeline
        ) { _ in
            releaseCalled = true
        }

        let firstSource = try FakeMediaSource(
            queue: playerSyncQueue,
            timeline: FakeTimeline(),
            trackGroupArray: FakeMediaSource.buildTrackGroupArray(formats: [])
        )

        try setupMediaSources([firstSource, preloadedSource])
        let playbackInfo = try #require(playbackInfo)

        try mediaPeriodQueue.updatePreloadConfiguration(
            new: PreloadConfiguration(targetPreloadDuration: .time(us: 5_000_000)),
            timeline: playbackInfo.timeline
        )

        try enqueueNext()
        try mediaPeriodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)

        #expect({
            let offsets = mediaPeriodHolderFactoryRendererPositionOffsets
            guard offsets.count == 2 else { return false }
            let first = offsets[0].microseconds
            let second = offsets[1].microseconds
            return first == 1_000_000_000_000 &&
                second == 1_000_010_000_000
        }())
        #expect(releaseCalled == false)

        try mediaPeriodQueue.updatePreloadConfiguration(
            new: .default,
            timeline: playbackInfo.timeline
        )

        #expect(releaseCalled)
    }

    @Test
    func `setPreloadConfiguration enablePreloading preloadHolderCreated`() throws {
        try setupTimelines([FakeTimeline(), FakeTimeline()])
        try enqueueNext()
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.count == 1)
        #expect(mediaPeriodHolderFactoryRendererPositionOffsets.first?.microseconds == 1_000_000_000_000)

        let playbackInfo = try #require(playbackInfo)
        try mediaPeriodQueue.updatePreloadConfiguration(
            new: PreloadConfiguration(targetPreloadDuration: .time(us: 5_000_000)),
            timeline: playbackInfo.timeline
        )

        #expect({
            let offsets = mediaPeriodHolderFactoryRendererPositionOffsets
            guard offsets.count == 2 else { return false }
            let first = offsets[0].microseconds
            let second = offsets[1].microseconds
            return first == 1_000_000_000_000 &&
                second == 1_000_010_000_000
        }())
    }

    private func setupAdTimeline(adGroupTimesUs: Int64...) throws {
        addPlaybackState = AdPlaybackState(adGroupTimes: adGroupTimesUs.map { .time(us: $0) })
            .withContentDuration(.time(us: contentDurationUs))
        let adTimeline = SinglePeriodAdTimeline(contentTimeline: contentTimeline, adPlaybackState: addPlaybackState)
        try setupTimelines([adTimeline])
    }

    private func setupTimelines(_ timelines: [Timeline]) throws {
        let mediaSorces = try timelines.map { try FakeMediaSource(queue: playerSyncQueue, timeline: $0) }
        try setupMediaSources(mediaSorces)
    }

    private func setupMediaSources(_ mediaSources: [FakeMediaSource]) throws {
        var holders = [MediaSourceList.MediaSourceHolder]()
        for source in mediaSources {
            fakeMediaSources.append(source)
            let mediaSourceHolder = MediaSourceList.MediaSourceHolder(
                queue: playerSyncQueue,
                mediaSource: source,
                useLazyPreparation: false
            )
            try mediaSourceHolder.mediaSource.prepareSource(
                delegate: self,
                mediaTransferListener: nil,
                playerId: playerId
            )
            holders.append(mediaSourceHolder)
        }

        try mediaSourceList.setMediaSource(
            holders: holders,
            shuffleOrder: FakeShuffleOrder(count: holders.count)
        )
        let playlistTimeline = mediaSourceList.createTimeline()
        firstPeriodId = playlistTimeline.id(for: 0)

        playbackInfo = try PlaybackInfo(
            clock: FakeClock(),
            timeline: playlistTimeline,
            periodId: mediaPeriodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
                timeline: playlistTimeline,
                periodId: firstPeriodId,
                position: .zero
            ),
            requestedContentPosition: .invalid,
            discontinuityStartPosition: .zero,
            state: .ready,
            playbackError: nil,
            isLoading: false,
            trackGroups: .empty,
            trackSelectorResult: TrackSelectorResult(
                rendererConfigurations: [],
                selections: [],
                tracks: .empty
            ),
            loadingMediaPeriodId: PlaybackInfo.placeholderMediaPeriodId,
            playWhenReady: false,
            playWhenReadyChangeReason: .userRequest,
            playbackSuppressionReason: .none,
            playbackParameters: .default,
            bufferedPosition: .zero,
            totalBufferedDuration: .zero,
            position: .zero,
            positionUpdateTime: .zero
        )
    }

    private func advance() throws {
        try enqueueNext()
        if mediaPeriodQueue.loading != mediaPeriodQueue.playing {
            advancePlaying()
        }
    }

    private func advancePlaying() { mediaPeriodQueue.advancePlayingPeriod() }

    private func advanceReading() { _ = mediaPeriodQueue.advanceReadingPeriod() }

    private func enqueueNext() throws {
        _ = try mediaPeriodQueue.enqueueNextMediaPeriodHolder(info: #require(getNextMediaPeriodInfo()))
    }

    private func clear() {
        mediaPeriodQueue.clear()
        playbackInfo = playbackInfo?.setPosition(
            periodId: mediaPeriodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
                timeline: mediaSourceList.createTimeline(),
                periodId: firstPeriodId,
                position: .zero
            ),
            position: .zero,
            requestedContentPosition: .invalid,
            discontinuityStartPosition: .zero,
            totalBufferedDuration: .zero,
            trackGroups: .empty,
            trackSelectorResult: .init(
                rendererConfigurations: [],
                selections: [],
                tracks: .empty
            )
        )
    }

    private func getNextMediaPeriodInfo() -> MediaPeriodInfo? {
        guard let playbackInfo else { return nil }
        return mediaPeriodQueue.nextMediaPeriodInfo(rendererPosition: .zero, playbackInfo: playbackInfo)
    }

    private func assertGetNextMediaPeriodInfoReturnsContentMediaPeriod(
        periodId: AnyHashable,
        startPositionUs: Int64,
        requestedContentPositionUs: Int64,
        endPositionUs: Int64,
        durationUs: Int64,
        isPrecededByTransitionFromSameStream: Bool,
        isFollowedByTransitionToSameStream: Bool,
        isLastInPeriod: Bool,
        isLastInWindow: Bool,
        isFinal: Bool,
        nextAdGroupIndex: Int?
    ) throws {
        let mediaPeriodInfo = try #require(getNextMediaPeriodInfo())
        let checkedMediaPeriodInfo = MediaPeriodInfo(
            id: MediaPeriodId(periodId: periodId, windowSequenceNumber: 0),
            startPosition: .time(us: startPositionUs),
            requestedContentPosition: .time(us: requestedContentPositionUs),
            endPosition: .time(us: endPositionUs),
            duration: .time(us: durationUs),
            isLastInTimelinePeriod: isLastInPeriod,
            isLastInTimelineWindow: isLastInWindow,
            isFinal: isFinal
        )

        #expect(mediaPeriodInfo == checkedMediaPeriodInfo)
    }
}

extension MediaPeriodQueueTest: MediaSourceDelegate {
    nonisolated func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline) throws {}
}
