//
//  SEPlayerTests.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Testing
@testable import SEPlayer
import CoreMedia

@TestableSyncPlayerActor
class SEPlayerTests {
    public let tag = "SEPlayerTests"
    public let timeoutMs: UInt64 = 10_000

    private let placeholderTimeline: Timeline

    init() {
        placeholderTimeline = MaskingMediaSource.PlaceholderTimeline(
            mediaItem: FakeTimeline.fakeMediaItem.buildUpon().setTag(0).build()
        )
    }

    @Test
    func playEmptyTimeline() async throws {
        let timeoutChecker = TimeoutChecker()
        let timeline = emptyTimeline
        let expectedMaskingTimeline = MaskingMediaSource.PlaceholderTimeline(mediaItem: FakeMediaSource.fakeMediaItem)
        let renderer = FakeRenderer(trackType: .unknown, clock: FakeClock())
        let player = try TestSEPlayerFactory().setRenderers([renderer]).build()
        let eventValidator = CollectablePlayerDelegateAsyncStream.EventValidator { event in
            if case let .didChangePlaybackState(state) = event {
                return state == .ended
            }
            return false
        }
        let playerEventsCollector = await CollectablePlayerDelegateAsyncStream(
            delegate: player.delegate,
            eventValidator: eventValidator
        )
        playerEventsCollector.startCollecting()

        try player.set(mediaSource: FakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        ))
        player.prepare()
        player.play()
        timeoutChecker.start(timeoutMs: timeoutMs) {
            eventValidator.continuation?.resume(throwing: $0)
        }
        try await withCheckedThrowingContinuation { continuation in
            eventValidator.continuation = continuation
        }
        timeoutChecker.cancel()

        let filteredTimelinesChanges = playerEventsCollector.events.filter {
            if case .didChangeTimeline = $0 { true } else { false }
        }

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[0] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: expectedMaskingTimeline) && reason == .playlistChanged
            } else {
                return false
            }
        }())

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[1] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: timeline) && reason == .sourceUpdate
            } else {
                return false
            }
        }())
        #expect(
            playerEventsCollector.events.filter {
                if case .didChangePositionDiscontinuity = $0 { true } else { false }
            }.isEmpty
        )
        #expect(renderer.formatsRead.isEmpty)
        #expect(renderer.sampleBufferReadCount == 0)
        #expect(renderer.isEnded() == false)

        player.release()
    }

    @Test
    func playSinglePeriodTimeline() async throws {
        let timeline = FakeTimeline()
        let renderer = FakeRenderer(trackType: .video, clock: FakeClock())
        let player = try TestSEPlayerFactory().setRenderers([renderer]).build()

        let eventValidator = CollectablePlayerDelegateAsyncStream.EventValidator { event in
            if case let .didChangePlaybackState(state) = event {
                return state == .ended
            }
            return false
        }
        let playerEventsCollector = await CollectablePlayerDelegateAsyncStream(
            delegate: player.delegate,
            eventValidator: eventValidator
        )
        playerEventsCollector.startCollecting()

        try player.set(mediaSource: FakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        ))
        player.prepare()
        player.play()
        try await withCheckedThrowingContinuation { continuation in
            eventValidator.continuation = continuation
        }
        let filteredTimelinesChanges = playerEventsCollector.events.filter {
            if case .didChangeTimeline = $0 { true } else { false }
        }

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[0] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: placeholderTimeline) && reason == .playlistChanged
            } else {
                return false
            }
        }())

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[1] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: timeline) && reason == .sourceUpdate
            } else {
                return false
            }
        }())

        #expect(
            playerEventsCollector.events.filter {
                if case .didChangePositionDiscontinuity = $0 { true } else { false }
            }.isEmpty
        )
        #expect(renderer.formatsRead[0] == SEPlayerTestRunner.videoFormat)
        #expect(renderer.sampleBufferReadCount == 1)
        #expect(renderer.isEnded())

        player.release()
    }

    @Test(.disabled("Flaky"))
    func playMultiPeriodTimeline() async throws {
        let timeoutChecker = TimeoutChecker()
        let timeline = FakeTimeline(windowCount: 3)
        let renderer = FakeRenderer(trackType: .video, clock: FakeClock())
        let player = try TestSEPlayerFactory().setRenderers([renderer]).build()
        let eventValidator = CollectablePlayerDelegateAsyncStream.EventValidator { event in
            if case let .didChangePlaybackState(state) = event {
                return state == .ended
            }
            return false
        }
        let playerEventsCollector = await CollectablePlayerDelegateAsyncStream(
            delegate: player.delegate,
            eventValidator: eventValidator
        )
        playerEventsCollector.startCollecting()

        try player.set(mediaSource: FakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        ))
        player.prepare()
        player.play()
        timeoutChecker.start(timeoutMs: timeoutMs) {
            eventValidator.continuation?.resume(throwing: $0)
        }
        try await withCheckedThrowingContinuation { continuation in
            eventValidator.continuation = continuation
        }
        timeoutChecker.cancel()

        let filteredTimelinesChanges = playerEventsCollector.events.filter {
            if case .didChangeTimeline = $0 { true } else { false }
        }

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[0] {
                return TestUtil.timelinesAreSame(
                    lhs: newTimeline,
                    rhs: FakeMediaSource.InitialTimeline(timeline: timeline)
                ) && reason == .playlistChanged
            } else {
                return false
            }
        }())
        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[1] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: timeline) && reason == .sourceUpdate
            } else {
                return false
            }
        }())
        #expect(
            playerEventsCollector.events.filter {
                if case let .didChangePositionDiscontinuity(_, _, r) = $0, r == .autoTransition { true } else { false }
            }.count == 2
        )
        #expect(renderer.formatsRead == Array(repeating: SEPlayerTestRunner.videoFormat, count: 3))
        #expect(renderer.sampleBufferReadCount == 3)
        #expect(renderer.isEnded())

        player.release()
    }

    @Test
    func playShortDurationPeriods() async throws {
        let timeoutChecker = TimeoutChecker()
        let timeline = FakeTimeline(windowDefinitions: [.init(periodCount: 100, id: 0)])
        let renderer = FakeRenderer(trackType: .video, clock: FakeClock())
        let player = try TestSEPlayerFactory().setRenderers([renderer]).build()
        let eventValidator = CollectablePlayerDelegateAsyncStream.EventValidator { event in
            if case let .didChangePlaybackState(state) = event {
                return state == .ended
            }
            return false
        }
        let playerEventsCollector = await CollectablePlayerDelegateAsyncStream(
            delegate: player.delegate,
            eventValidator: eventValidator
        )
        playerEventsCollector.startCollecting()
        try player.set(mediaSource: FakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        ))
        player.prepare()
        player.play()
        timeoutChecker.start(timeoutMs: timeoutMs) {
            eventValidator.continuation?.resume(throwing: $0)
        }
        try await withCheckedThrowingContinuation { continuation in
            eventValidator.continuation = continuation
        }
        let filteredTimelinesChanges = playerEventsCollector.events.filter {
            if case .didChangeTimeline = $0 { true } else { false }
        }

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[0] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: placeholderTimeline) && reason == .playlistChanged
            } else {
                return false
            }
        }())

        #expect({
            if case let .didChangeTimeline(newTimeline, reason) = filteredTimelinesChanges[1] {
                return TestUtil.timelinesAreSame(lhs: newTimeline, rhs: timeline) && reason == .sourceUpdate
            } else {
                return false
            }
        }())
        #expect(
            playerEventsCollector.events.filter { element in
                if case let .didChangePositionDiscontinuity(_, _, reason) = element {
                    return reason == .autoTransition
                }
                return false
            }.count == 99
        )
        withKnownIssue {
            #expect(renderer.formatsRead.count == 100)
            #expect(renderer.sampleBufferReadCount == 100)
        }
        #expect(renderer.isEnded())
        player.release()
    }

    @Test
    func `renderersLifecycle renderersThatAreNeverEnabled areNotReset`() async throws {
        let timeoutChecker = TimeoutChecker()
        let timeline = FakeTimeline()
        let clock = FakeClock()
        let videoRenderer = FakeRenderer(trackType: .video, clock: clock)
        let audioRenderer = FakeRenderer(trackType: .audio, clock: clock)
        let player = try TestSEPlayerFactory().setRenderers([videoRenderer, audioRenderer]).build()
        let playerEventsCollector = await CollectablePlayerDelegateAsyncStream(
            delegate: player.delegate,
            eventValidator: .waitForState(state: .ended)
        )
        playerEventsCollector.startCollecting()
        player.set(mediaSource: try FakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.audioFormat]
        ))
        player.prepare()
        player.play()

        timeoutChecker.start(timeoutMs: timeoutMs) { error in
            playerEventsCollector.eventValidator.continuation?.resume(throwing: error)
        }
        try await withCheckedThrowingContinuation { continuation in
            playerEventsCollector.eventValidator.continuation = continuation
        }
        await player.releaseAsync()

        #expect(audioRenderer.enabledCount == 1)
        #expect(audioRenderer.resetCount == 1)
        #expect(videoRenderer.enabledCount == 0)
        #expect(videoRenderer.resetCount == 0)
    }

    @Test(.disabled())
    func `renderersLifecycle onlyRenderersThatAreEnabled areSetToFinal`() async throws {
//        var videoStreamSetToFinalCount = 0
//        let clock = FakeClock()
//        let videoRenderer = FakeRenderer(trackType: .video, clock: clock)
//        let audioRenderer = FakeRenderer(trackType: .audio, clock: clock)
//
//        final class TestForwardingRenderer: ForwardingRenderer {
//            let onEvent: () -> Void
//            init(renderer: SERenderer, onEvent: @escaping () -> Void) {
//                self.onEvent = onEvent
//                super.init(renderer: renderer)
//            }
//
//            override func setStreamFinal() {
//                super.setStreamFinal()
//                onEvent()
//            }
//        }
//
//        let forwardingVideoRenderer = TestForwardingRenderer(renderer: videoRenderer) {
//            videoStreamSetToFinalCount += 1
//        }
    }

    @Test
    func seekDiscontinuity() async throws {
        let timeline = FakeTimeline()
        let actionSchedule = ActionSchedule.Builder(tag: tag).seek(positionMs: 10).build()
        let testRunner = try await SEPlayerTestRunner.Builder()
            .setTimeline(timeline)
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertPositionDiscontinuityReasonsEqual(discontinuityReasons: .seek)
    }

    @Test
    func seekDiscontinuityWithAdjustment() async throws {
        let timeline = FakeTimeline(windowCount: 1)

        final class MediaSourceMock: FakeMediaSource {
            override func createMediaPeriod(
                id: MediaPeriodId,
                trackGroups: [TrackGroup],
                allocator: Allocator,
                transferListener: TransferListener?
            ) throws -> FakeMediaPeriod {
                let period = try FakeMediaPeriod(
                    queue: queue,
                    trackGroups: trackGroups,
                    allocator: allocator,
                    singleSampleTimeUs: FakeTimeline.TimelineWindowDefinition
                        .defaultWindowOffsetInFirstPeriodUs,
                    deferOnPrepared: false
                )
                period.setSeekToUsOffset(10)
                return period
            }
        }

        let mediaSource = try MediaSourceMock(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        )

        let actionSchedule = ActionSchedule.Builder(tag: tag)
            .pause()
            .waitForPlaybackState(.ready)
            .seek(positionMs: 10)
            .play()
            .build()

        let testRunner = try await SEPlayerTestRunner.Builder()
            .setMediaSources([mediaSource])
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertPositionDiscontinuityReasonsEqual(
            discontinuityReasons: .seek, .seekAdjustment
        )
    }

    @Test
    func internalDiscontinuityAtNewPosition() async throws {
        let timeline = FakeTimeline(windowCount: 1)
        final class TestFakeMediaSource: FakeMediaSource {
            override func createMediaPeriod(id: MediaPeriodId, trackGroups: [TrackGroup], allocator: Allocator, transferListener: TransferListener?) throws -> FakeMediaPeriod {
                let mediaPeriod = try FakeMediaPeriod(
                    queue: queue,
                    trackGroups: trackGroups,
                    allocator: allocator,
                    singleSampleTimeUs: FakeTimeline.TimelineWindowDefinition.defaultWindowOffsetInFirstPeriodUs,
                )
                mediaPeriod.setDiscontinuityPositionUs(10)
                return mediaPeriod
            }
        }
        let mediaSource = try TestFakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        )
        let testRunner = try await SEPlayerTestRunner.Builder().setMediaSources([mediaSource])
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertPositionDiscontinuityReasonsEqual(discontinuityReasons: .internal)
    }

    @Test
    func internalDiscontinuityAtInitialPosition() async throws {
        let timeline = FakeTimeline()

        final class TestFakeMediaSource: FakeMediaSource {
            let timelineRef: FakeTimeline

            init(queue: Queue, timeline: FakeTimeline, formats: [Format]) throws {
                self.timelineRef = timeline
                try super.init(queue: queue, timeline: timeline, trackGroups: Self.buildTrackGroups(formats: formats))
            }

            override func createMediaPeriod(
                id: MediaPeriodId,
                trackGroups: [TrackGroup],
                allocator: Allocator,
                transferListener: TransferListener?
            ) throws -> FakeMediaPeriod {
                let mediaPeriod = try FakeMediaPeriod(
                    queue: queue,
                    trackGroups: trackGroups,
                    allocator: allocator,
                    singleSampleTimeUs: FakeTimeline.TimelineWindowDefinition.defaultWindowOffsetInFirstPeriodUs
                )

                mediaPeriod.setDiscontinuityPositionUs(
                    timelineRef.getWindow(windowIndex: 0, window: Window()).positionInFirstPeriodUs
                )

                return mediaPeriod
            }
        }

        let mediaSource = try TestFakeMediaSource(
            queue: playerSyncQueue,
            timeline: timeline,
            formats: [SEPlayerTestRunner.videoFormat]
        )

        let testRunner = try await SEPlayerTestRunner.Builder()
            .setMediaSources([mediaSource])
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertNoPositionDiscontinuities()
    }

    @Test
    func dynamicTimelineChangeReason() async throws {
        let timeline = FakeTimeline(windowDefinitions: [.init(isSeekable: false, isDynamic: false, durationUs: 100000)])
        let timeline2 = FakeTimeline(windowDefinitions: [.init(isSeekable: false, isDynamic: false, durationUs: 20000)])
        let mediaSource = try FakeMediaSource(timeline: timeline, formats: [SEPlayerTestRunner.videoFormat])
        let actionSchedule = try ActionSchedule.Builder(tag: tag)
            .pause()
            .waitForTimelineChanged(expectedTimeline: timeline, expectedReason: .sourceUpdate)
            .executeClosure { _ in try mediaSource.setNewSourceInfo(newTimeline: timeline2) }
            .waitForTimelineChanged(expectedTimeline: timeline2, expectedReason: .sourceUpdate)
            .play()
            .build()

        let testRunner = try await SEPlayerTestRunner.Builder()
            .setMediaSources([mediaSource])
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertTimelinesSame(timelines: placeholderTimeline, timeline, timeline2)
        testRunner.assertTimelineChangeReasonsEqual(reasons: .playlistChanged, .sourceUpdate, .sourceUpdate)
    }

    @Test(.disabled("Timeout"))
    func `seekBeforePreparationCompletes seeksToCorrectPosition`() async throws {
        let createPeriodCalledCountDownLatch = CountDownLatch(count: 1)
        var fakeMediaPeriodHolder = [FakeMediaPeriod]()

        final class TestFakeMediaSource: FakeMediaSource {
            let countDownLatch: CountDownLatch
            let onPeriodCreated: (FakeMediaPeriod) -> Void

            init(
                queue: Queue,
                countDownLatch: CountDownLatch,
                onPeriodCreated: @escaping (FakeMediaPeriod) -> Void,
                formats: [Format]
            ) throws {
                self.countDownLatch = countDownLatch
                self.onPeriodCreated = onPeriodCreated
                try super.init(queue: queue, timeline: nil, trackGroups: Self.buildTrackGroups(formats: formats))
            }

            override func createMediaPeriod(
                id: MediaPeriodId,
                trackGroups: [TrackGroup],
                allocator: Allocator,
                transferListener: TransferListener?
            ) throws -> FakeMediaPeriod {
                let mediaPeriod = try FakeMediaPeriod(
                    queue: queue,
                    trackGroups: trackGroups,
                    allocator: allocator,
                    singleSampleTimeUs: FakeTimeline.TimelineWindowDefinition.defaultWindowOffsetInFirstPeriodUs,
                    deferOnPrepared: true
                )
                onPeriodCreated(mediaPeriod)
                countDownLatch.countDown()

                return mediaPeriod
            }
        }

        let mediaSource = try TestFakeMediaSource(
            queue: playerSyncQueue,
            countDownLatch: createPeriodCalledCountDownLatch,
            onPeriodCreated: { fakeMediaPeriodHolder.append($0) },
            formats: [SEPlayerTestRunner.videoFormat]
        )

        var positionWhenReady = Int64.zero
        let actionSchedule = try ActionSchedule.Builder(tag: tag)
            .pause()
            .waitForPlaybackState(.buffering)
            .delay(1)
            .executeClosure { _ in
                try mediaSource.setNewSourceInfo(newTimeline: FakeTimeline())
            }
            .waitForTimelineChanged()
            .executeClosure { _ in
                try await createPeriodCalledCountDownLatch.awaitResult(timeoutMs: self.timeoutMs)
            }
            .seek(positionMs: 5000)
            .executeClosure { _ in fakeMediaPeriodHolder[0].setPreparationComplete() }
            .waitForPlaybackState(.ready)
            .executeClosure {
                positionWhenReady = $0.currentPosition
            }
            .play()
            .build()

        try await SEPlayerTestRunner.Builder()
            .initialSeek(0, positionMs: 2000)
            .setMediaSources([mediaSource])
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilEnded(timeoutMs: timeoutMs)

        #expect(positionWhenReady >= 5000)
    }

    @Test
    func `stop correctMasking`() async throws {
        var currentMediaItemIndex = Array<Int?>(repeating: nil, count: 3)
        var currentPosition = Array<Int64>(repeating: .timeUnset, count: 3)
        var bufferedPosition = Array<Int64>(repeating: .timeUnset, count: 3)
        var totalBufferedDuration = Array<Int64>(repeating: .timeUnset, count: 3)
        let mediaSource = try FakeMediaSource(
            queue: playerSyncQueue,
            timeline: FakeTimeline(),
            formats: [SEPlayerTestRunner.videoFormat]
        )
        let actionSchedule = try ActionSchedule.Builder(tag: tag)
            .pause()
            .seek(mediaItemIndex: 1, positionMs: 1000)
            .waitForPlaybackState(.ready)
            .executeClosure { player in
                currentMediaItemIndex[0] = player.currentMediaItemIndex
                currentPosition[0] = player.currentPosition
                bufferedPosition[0] = player.bufferedPosition
                totalBufferedDuration[0] = player.totalBufferedDuration
                player.stop()
                currentMediaItemIndex[1] = player.currentMediaItemIndex
                currentPosition[1] = player.currentPosition
                bufferedPosition[1] = player.bufferedPosition
                totalBufferedDuration[1] = player.totalBufferedDuration
            }
            .waitForPlaybackState(.idle)
            .delay(10)
            .executeClosure { player in
                currentMediaItemIndex[2] = player.currentMediaItemIndex
                currentPosition[2] = player.currentPosition
                bufferedPosition[2] = player.bufferedPosition
                totalBufferedDuration[2] = player.totalBufferedDuration
            }
            .build()

        let testRunner = try await SEPlayerTestRunner.Builder()
            .setMediaSources([mediaSource, mediaSource])
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilActionScheduleFinished(timeoutMs: timeoutMs)
            .blockUntilEnded(timeoutMs: timeoutMs)

        testRunner.assertTimelineChangeReasonsEqual(reasons: .playlistChanged, .sourceUpdate, .sourceUpdate)
        testRunner.assertPositionDiscontinuityReasonsEqual(discontinuityReasons: .seek)

        #expect(currentMediaItemIndex[0] == 1)
        #expect(currentPosition[0] == 1000)
        #expect(bufferedPosition[0] == 10000)
        #expect(totalBufferedDuration[0] == 9000)

        #expect(currentMediaItemIndex[1] == 1)
        #expect(currentPosition[1] == 1000)
        #expect(bufferedPosition[1] == 1000)
        #expect(totalBufferedDuration[1] == 0)

        #expect(currentMediaItemIndex[2] == 1)
        #expect(currentPosition[2] == 1000)
        #expect(bufferedPosition[2] == 1000)
        #expect(totalBufferedDuration[2] == 0)
    }

    @Test(.disabled("Flaky"))
    func `seekTo singlePeriod correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 9000) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [createPartiallyBufferedMediaSource(maxBufferedPositionMs: 9200)]
        )

        #expect(mediaItemIndex[0] == 0)
        #expect(positionMs[0] == 9000)
        #expect(bufferedPositions[0] == 9200)
        #expect(totalBufferedDuration[0] == 200)

        #expect(mediaItemIndex[1] == mediaItemIndex[0])
        #expect(positionMs[1] == positionMs[0])
        #expect(bufferedPositions[1] == 9200)
        #expect(totalBufferedDuration[1] == 200)
    }

    @Test
    func `seekTo singlePeriod beyondBufferedData correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 9200) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [createPartiallyBufferedMediaSource(maxBufferedPositionMs: 9200)]
        )

        #expect(mediaItemIndex[0] == 0)
        #expect(positionMs[0] == 9200)
        #expect(bufferedPositions[0] == 9200)
        #expect(totalBufferedDuration[0] == 0)

        #expect(mediaItemIndex[1] == mediaItemIndex[0])
        #expect(positionMs[1] == positionMs[0])
        #expect(bufferedPositions[1] == 9200)
        #expect(totalBufferedDuration[1] == 0)
    }

    @Test
    func `seekTo backwardsSinglePeriod correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 1000) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [createPartiallyBufferedMediaSource(maxBufferedPositionMs: 9200)]
        )

        #expect(mediaItemIndex[0] == 0)
        #expect(positionMs[0] == 1000)
        #expect(bufferedPositions[0] == 1000)
        #expect(totalBufferedDuration[0] == 0)
    }

    @Test(.disabled("Flaky"))
    func `seekTo backwardsMultiplePeriods correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 1000, of: 0) },
            pauseMediaItemIndex: 1,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [
                try FakeMediaSource(),
                try FakeMediaSource(),
                createPartiallyBufferedMediaSource(maxBufferedPositionMs: 9200)
            ]
        )

        #expect(mediaItemIndex[0] == 0)
        #expect(positionMs[0] == 1000)
        #expect(bufferedPositions[0] == 1000)
        #expect(totalBufferedDuration[0] == 0)
    }

    @Test(.disabled("Flaky"))
    func `seekTo toUnbufferedPeriod correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 1000, of: 2) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [
                try FakeMediaSource(),
                try FakeMediaSource(),
                createPartiallyBufferedMediaSource(maxBufferedPositionMs: 0)
            ]
        )

        #expect(mediaItemIndex[0] == 2)
        #expect(positionMs[0] == 1000)
        #expect(bufferedPositions[0] == 1000)
        #expect(totalBufferedDuration[0] == 0)
    }

    @Test(.disabled("Timeout"))
    func `seekTo toLoadingPeriod correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 1000, of: 1) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [
                try FakeMediaSource(),
                try FakeMediaSource()
            ]
        )

        #expect(mediaItemIndex[0] == 1)
        #expect(positionMs[0] == 1000)
        withKnownIssue {
            #expect(bufferedPositions[0] == 10000)
            let position = try #require(positionMs[0])
            #expect(totalBufferedDuration[0] == 10000 - position)
        }

        #expect(mediaItemIndex[1] == mediaItemIndex[0])
        #expect(positionMs[1] == positionMs[0])
        #expect(bufferedPositions[1] == 10000)

        let position = try #require(positionMs[1])
        #expect(totalBufferedDuration[1] == 10000 - position)
    }

    @Test(.disabled("Timeout"))
    func `seekTo toLoadingPeriod withinPartiallyBufferedData correctMaskingPosition`() async throws {
        var mediaItemIndex = Array<Int?>(repeating: nil, count: 2)
        var positionMs = Array<Int64?>(repeating: nil, count: 2)
        var bufferedPositions = Array<Int64?>(repeating: nil, count: 2)
        var totalBufferedDuration = Array<Int64?>(repeating: nil, count: 2)

        try await runPositionMaskingCapturingActionSchedule(
            callback: { $0.seek(to: 1000, of: 1) },
            pauseMediaItemIndex: 0,
            mediaItemIndexUpdate: { mediaItemIndex[$0] = $1 },
            positionMsUpdate: { positionMs[$0] = $1 },
            bufferedPositionUpdate: { bufferedPositions[$0] = $1 },
            totalBufferedDurationUpdate: { totalBufferedDuration[$0] = $1 },
            mediaSources: [
                try FakeMediaSource(),
                createPartiallyBufferedMediaSource(maxBufferedPositionMs: 4000)
            ]
        )

        #expect(mediaItemIndex[0] == 1)
        #expect(positionMs[0] == 1000)
        withKnownIssue {
            #expect(bufferedPositions[0] == 1000)
            #expect(totalBufferedDuration[0] == 0)
        }

        #expect(mediaItemIndex[1] == mediaItemIndex[0])
        #expect(positionMs[1] == positionMs[0])
        #expect(bufferedPositions[1] == 4000)
        #expect(totalBufferedDuration[1] == 3000)
    }

    @TestableSyncPlayerActor
    private func runPositionMaskingCapturingActionSchedule(
        callback: @escaping (SEPlayer) async throws -> Void,
        pauseMediaItemIndex: Int,
        mediaItemIndexUpdate: @escaping (Int, Int) -> Void,
        positionMsUpdate: @escaping (Int, Int64) -> Void,
        bufferedPositionUpdate: @escaping (Int, Int64) -> Void,
        totalBufferedDurationUpdate: @escaping (Int, Int64) -> Void,
        mediaSources: [MediaSource]
    ) async throws {
        let actionSchedule = try ActionSchedule.Builder(tag: tag)
            .playUntilPosition(mediaItemIndex: pauseMediaItemIndex, positionMs: 8000)
            .executeClosure(callback)
            .executeClosure { player in
                mediaItemIndexUpdate(0, player.currentMediaItemIndex)
                positionMsUpdate(0, player.currentPosition)
                bufferedPositionUpdate(0, player.bufferedPosition)
                totalBufferedDurationUpdate(0, player.totalBufferedDuration)
            }
            .waitForPendingPlayerCommands()
            .executeClosure { player in
                mediaItemIndexUpdate(1, player.currentMediaItemIndex)
                positionMsUpdate(1, player.currentPosition)
                bufferedPositionUpdate(1, player.bufferedPosition)
                totalBufferedDurationUpdate(1, player.totalBufferedDuration)
            }
            .stop()
            .build()

        try await SEPlayerTestRunner.Builder()
            .setMediaSources(mediaSources)
            .setActionSchedule(actionSchedule)
            .build()
            .start()
            .blockUntilActionScheduleFinished(timeoutMs: timeoutMs)
            .blockUntilEnded(timeoutMs: timeoutMs)
    }

    private func createPartiallyBufferedMediaSource(maxBufferedPositionMs: Int64) throws -> FakeMediaSource {
        let windowOffsetInFirstPeriodUs: Int64 = 1_000_000
        let fakeTimeline = FakeTimeline(
            windowDefinitions: [
                .init(
                    periodCount: 1,
                    id: 1,
                    isSeekable: false,
                    isDynamic: false,
                    isLive: false,
                    isPlaceholder: false,
                    durationUs: 10_000_000,
                    defaultPositionUs: 0,
                    windowOffsetInFirstPeriodUs: windowOffsetInFirstPeriodUs,
                    adPlaybackStates: [.none]
                )
            ]
        )

        final class TestFakeMediaSource: FakeMediaSource {
            var windowOffsetInFirstPeriodUs: Int64 = .zero
            var maxBufferedPositionMs: Int64 = .zero

            override func createMediaPeriod(
                id: MediaPeriodId,
                trackGroups: [TrackGroup],
                allocator: Allocator,
                transferListener: TransferListener?
            ) throws -> FakeMediaPeriod {
                try FakeMediaPeriod(
                    queue: queue,
                    trackGroups: trackGroups,
                    allocator: allocator,
                    trackDataFactory: TestTrackDataFactory(
                        windowOffsetInFirstPeriodUs: windowOffsetInFirstPeriodUs,
                        maxBufferedPositionMs: maxBufferedPositionMs,
                    ),
                    deferOnPrepared: false
                )
            }

            struct TestTrackDataFactory: FakeMediaPeriod.TrackDataFactory {
                let windowOffsetInFirstPeriodUs: Int64
                let maxBufferedPositionMs: Int64

                func create(format: Format, mediaPeriodId: MediaPeriodId) -> [FakeSampleStream.FakeSampleStreamItem] {
                    [
                        .init(oneByteSample: windowOffsetInFirstPeriodUs, flags: .keyframe),
                        .init(
                            oneByteSample: windowOffsetInFirstPeriodUs + Time.msToUs(timeMs: maxBufferedPositionMs),
                            flags: .keyframe
                        )
                    ]
                }
            }
        }

        let mediaSource = try TestFakeMediaSource(timeline: fakeTimeline, formats: [SEPlayerTestRunner.videoFormat])
        mediaSource.windowOffsetInFirstPeriodUs = windowOffsetInFirstPeriodUs
        mediaSource.maxBufferedPositionMs = maxBufferedPositionMs
        return mediaSource
    }
}
