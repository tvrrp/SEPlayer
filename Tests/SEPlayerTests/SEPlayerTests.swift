//
//  SEPlayerTests.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

import Testing
@testable import SEPlayer

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
        await withCheckedContinuation { continuation in
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

    @Test(.disabled())
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

                var window = Window()
                mediaPeriod.setDiscontinuityPositionUs(
                    timelineRef.getWindow(windowIndex: 0, window: &window).positionInFirstPeriodUs
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
}
