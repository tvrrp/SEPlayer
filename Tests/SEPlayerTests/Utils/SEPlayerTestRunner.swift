//
//  SEPlayerTestRunner.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.test.utils.ExoPlayerTestRunner
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
@testable import SEPlayer
import Testing

final class SEPlayerTestRunner: @unchecked Sendable {
    /// H.264 with parameter sets that only start like real ones: the tests decode nothing, but a sample queue
    /// describes every sample it hands out.
    static let videoFormat = AnyFormat(VideoFormat {
        $0.codecType = FourCharacterCode(kCMVideoCodecType_H264)
        $0.codec = .h264 {
            $0.profile = .high
            $0.level = .init(rawValue: 31)
            $0.sequenceParameterSets = [Data([0x67, 0x64, 0x00, 0x1F])]
            $0.pictureParameterSets = [Data([0x68, 0xEB, 0xE3, 0xCB])]
        }
        $0.averageBitrate = 800_000
        $0.size = VideoSize(width: 1280, height: 720)
    })

    /// AAC LC at 44100 Hz in stereo.
    static let audioFormat = AnyFormat(AudioFormat {
        $0.codec = .aac {
            $0.objectType = .lowComplexity
            $0.coreSampleRate = 44100
            $0.channelConfiguration = 2
            $0.audioSpecificConfig = Data([0x12, 0x10])
        }
        $0.codecs = "mp4a.40.2"
        $0.averageBitrate = 100_000
        $0.channelCount = 2
        $0.sampleRate = 44100
    })

    final class Builder {
        private let queue: Queue
        private let playerFactory: TestSEPlayerFactory
        private var timeline: Timeline?
        private var mediaSources: [MediaSource]
        private var supportedFormats: [AnyFormat]
        private var actionSchedule: ActionSchedule?
        private var view: SEPlayerLayer?
        private weak var playerDelegate: SEPlayerDelegate?
        private var expectedPlayerEndedCount: Int?
        private var pauseAtEndOfMediaItems = false
        private var initialMediaItemIndex: Int?
        private var initialPositionMs: Int64
        private var skipSettingMediaSources = false

        init(queue: Queue = playerSyncQueue, factory: TestSEPlayerFactory? = nil) throws {
            self.queue = queue
            playerFactory = try factory ?? TestSEPlayerFactory(queue: queue)
            mediaSources = []
            supportedFormats = [videoFormat]
            initialPositionMs = .timeUnset
        }

        @discardableResult
        func setTimeline(_ timline: Timeline) -> Builder {
            #expect(mediaSources.isEmpty)
            #expect(!skipSettingMediaSources)
            self.timeline = timline
            return self
        }

        @discardableResult
        func initialSeek(_ mediaItemIndex: Int, positionMs: Int64) -> Builder {
            self.initialMediaItemIndex = mediaItemIndex
            self.initialPositionMs = positionMs
            return self
        }

        @discardableResult
        func setMediaSources(_ mediaSources: [MediaSource]) -> Builder {
            #expect(timeline == nil)
            #expect(!skipSettingMediaSources)
            self.mediaSources = mediaSources
            return self
        }

        @discardableResult
        func setSupportedFormats(_ supportedFormats: AnyFormat...) -> Builder {
            self.supportedFormats = supportedFormats
            return self
        }

        @discardableResult
        func setSkipSettingMediaSources() -> Builder {
            #expect(timeline == nil)
            #expect(mediaSources.isEmpty)
            self.skipSettingMediaSources = true
            return self
        }

        @discardableResult
        func setUseLazyPreparation(_ useLazyPreparation: Bool) -> Builder {
            playerFactory.setUseLazyPreparation(useLazyPreparation)
            return self
        }

        @discardableResult
        func setPauseAtEndOfMediaItems(_ pauseAtEndOfMediaItems: Bool) -> Builder {
            self.pauseAtEndOfMediaItems = pauseAtEndOfMediaItems
            return self
        }

        func setRenderers(_ renderers: [SERenderer]) -> Builder {
            playerFactory.setRenderers(renderers)
            return self
        }

        @discardableResult
        func setActionSchedule(_ actionSchedule: ActionSchedule) -> Builder {
            self.actionSchedule = actionSchedule
            return self
        }

        @discardableResult
        func setVideoView(_ view: SEPlayerLayer) -> Builder {
            self.view = view
            return self
        }

        @discardableResult
        func setPlayerDelegate(_ playerDelegate: SEPlayerDelegate) -> Builder {
            self.playerDelegate = playerDelegate
            return self
        }

        @discardableResult
        func setExpectedPlayerEndedCount(_ expectedPlayerEndedCount: Int) -> Builder {
            self.expectedPlayerEndedCount = expectedPlayerEndedCount
            return self
        }

        func build() throws -> SEPlayerTestRunner {
            if mediaSources.isEmpty, !skipSettingMediaSources {
                if timeline == nil {
                    timeline = FakeTimeline()
                }
                guard let timeline else {
                    throw ErrorBuilder.illegalState()
                }
                try mediaSources.append(FakeMediaSource(
                    queue: queue,
                    timeline: timeline,
                    formats: supportedFormats
                ))
            }

            return SEPlayerTestRunner(
                queue: queue,
                playerFactory: playerFactory,
                mediaSources: mediaSources,
                skipSettingMediaSources: skipSettingMediaSources,
                initialMediaItemIndex: initialMediaItemIndex,
                initialPositionMs: initialPositionMs,
                view: view,
                actionSchedule: actionSchedule,
                playerDelegate: playerDelegate,
                expectedPlayerEndedCount: expectedPlayerEndedCount ?? 1,
                pauseAtEndOfMediaItems: pauseAtEndOfMediaItems
            )
        }
    }

    private let queue: Queue
    private let playerFactory: TestSEPlayerFactory
    private let mediaSources: [MediaSource]
    private let skipSettingMediaSources: Bool
    private let initialMediaItemIndex: Int?
    private let initialPositionMs: Int64
    private let view: SEPlayerLayer?
    private let actionSchedule: ActionSchedule?
    private weak var playerDelegate: SEPlayerDelegate?
    private let endedCountDownLatch: CountDownLatch
    private let actionScheduleFinishedCountDownLatch: CountDownLatch
    private var timelines: [Timeline]
    private var timelineChangeReasons: [TimelineChangeReason]
    private var mediaItems: [MediaItem]
    private var mediaItemTransitionReasons: [MediaItemTransitionReason?]
    private var periodIndices: [Int?]
    private var discontinuityReasons: [DiscontinuityReason]
    private var playbackStates: [PlayerState]
    private let pauseAtEndOfMediaItems: Bool

    private var player: SEPlayer?
    private var error: Error?
    private var playerWasPrepared = false

    fileprivate init(
        queue: Queue,
        playerFactory: TestSEPlayerFactory,
        mediaSources: [MediaSource],
        skipSettingMediaSources: Bool,
        initialMediaItemIndex: Int?,
        initialPositionMs: Int64,
        view: SEPlayerLayer?,
        actionSchedule: ActionSchedule?,
        playerDelegate: SEPlayerDelegate?,
        expectedPlayerEndedCount: Int,
        pauseAtEndOfMediaItems: Bool
    ) {
        self.queue = queue
        self.playerFactory = playerFactory
        self.mediaSources = mediaSources
        self.skipSettingMediaSources = skipSettingMediaSources
        self.initialMediaItemIndex = initialMediaItemIndex
        self.initialPositionMs = initialPositionMs
        self.view = view
        self.actionSchedule = actionSchedule
        self.playerDelegate = playerDelegate
        self.pauseAtEndOfMediaItems = pauseAtEndOfMediaItems

        timelines = []
        timelineChangeReasons = []
        mediaItems = []
        mediaItemTransitionReasons = []
        periodIndices = []
        discontinuityReasons = []
        playbackStates = []
        endedCountDownLatch = CountDownLatch(count: expectedPlayerEndedCount)
        actionScheduleFinishedCountDownLatch = CountDownLatch(count: actionSchedule != nil ? 1 : 0)
    }

    @discardableResult
    func start(doPrepare: Bool = true, isolation: isolated any Actor = #isolation) -> Self {
        isolation.assertIsolated()
        Task { // @MainActor in
            do {
                let player = try playerFactory.setQueue(queue).build()
                self.player = player
                if let view {
                    await MainActor.run { view.player = player }
                }
                if pauseAtEndOfMediaItems {
                    player.pauseAtTheEndOfMediaItem = true
                }
                await collectPlayerEvents(player: player, isolation: isolation)
                if let playerDelegate {
                    await player.delegate.addDelegate(playerDelegate)
                }
                player.play()

                if let actionSchedule {
                    let start = {
                        try await actionSchedule.start(
                            player: player,
                            trackSelector: DefaultTrackSelector(),
                            view: self.view,
                            callback: self,
                            isolation: isolation
                        )
                    }
                    if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *) {
                        Task.immediate { try await start() }
                    } else {
                        Task { try await start() }
                    }
                }
                if let initialMediaItemIndex {
                    player.seek(to: CMTime(value: initialPositionMs, timescale: 1000), of: initialMediaItemIndex)
                }
                if !skipSettingMediaSources {
                    player.set(mediaSources: mediaSources, resetPosition: false)
                }
                if doPrepare {
                    player.prepare()
                }
                // TODO: Call try await value actionScheduleValue
            } catch {
                handleError(error: error, isolation: isolation)
            }
        }

        return self
    }

    @discardableResult
    func blockUntilEnded(timeoutMs: UInt64, isolation: isolated any Actor = #isolation) async throws -> Self {
        isolation.assertIsolated()
        do {
            try await endedCountDownLatch.awaitResult(timeoutMs: timeoutMs)
        } catch {
            self.error = error
        }

        actionSchedule?.stop()
        self.player?.release()
        if let error {
            throw error
        }
        return self
    }

    @discardableResult
    func blockUntilActionScheduleFinished(timeoutMs: UInt64, isolation: isolated any Actor = #isolation) async throws -> Self {
        isolation.assertIsolated()
        do {
            try await actionScheduleFinishedCountDownLatch.awaitResult(timeoutMs: timeoutMs)
        } catch {
            // A player left playing would go on running on the shared queue during the next tests.
            actionSchedule?.stop()
            player?.release()
            throw error
        }
        return self
    }

    func assertTimelinesSame(timelines: Timeline...) {
        #expect(zip(self.timelines, timelines).allSatisfy {
            TestUtil.timelinesAreSame(lhs: $0, rhs: $1)
        })
    }

    func assertTimelineChangeReasonsEqual(reasons: TimelineChangeReason...) {
        print()
        #expect(timelineChangeReasons.count == reasons.count)
        #expect(zip(timelineChangeReasons, reasons).allSatisfy { $0 == $1 })
    }

    func assertPlaybackStatesEqual(states: PlayerState...) {
        #expect(playbackStates.count == states.count)
        #expect(zip(playbackStates, states).allSatisfy { $0 == $1 })
    }

    func assertNoPositionDiscontinuities() {
        #expect(discontinuityReasons.isEmpty)
    }

    func assertPositionDiscontinuityReasonsEqual(discontinuityReasons: DiscontinuityReason...) {
        #expect(self.discontinuityReasons.count == discontinuityReasons.count)
        #expect(zip(self.discontinuityReasons, discontinuityReasons).allSatisfy { $0 == $1 })
    }

    func assertPlayedPeriodIndices(periodIndices: Int...) {
        #expect(self.periodIndices.count == periodIndices.count)
        #expect(zip(self.periodIndices, periodIndices).allSatisfy { $0 == $1 })
    }

    private func handleError(error: Error, isolation: isolated any Actor) {
        isolation.assertIsolated()
        while endedCountDownLatch.getCount() > 0 {
            endedCountDownLatch.countDown()
        }
    }

    @MainActor
    private func collectPlayerEvents(player: SEPlayer, isolation: any Actor) {
        let playerDelegateStream = PlayerDelegateAsyncStream(delegate: player.delegate)

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                for await event in playerDelegateStream.start() {
                    try await handleEvent(event: event, isolation: isolation)
                }
            } catch {
                await handleError(error: error, isolation: isolation)
            }
        }
    }

    private func handleEvent(event: PlayerDelegateAsyncStream.Event, isolation: isolated any Actor) throws {
        isolation.assertIsolated()

        switch event {
        case let .didChangeTimeline(timeline, reason):
            print("👹 didChangeTimeline, reason = \(reason)")
            timelineChangeReasons.append(reason)
            timelines.append(timeline)
            let currentIndex = try #require(player).currentPeriodIndex
            if periodIndices.last != currentIndex {
                // Ignore timeline changes that do not change the period index.
                periodIndices.append(currentIndex)
            }
        case let .didTransitionMediaItem(mediaItem, reason):
            if let mediaItem {
                mediaItems.append(mediaItem)
            }
            mediaItemTransitionReasons.append(reason)
        case let .didChangePlaybackState(state):
            playbackStates.append(state)
            playerWasPrepared = playerWasPrepared || state != .idle
            if state == .ended || state == .idle && playerWasPrepared {
                endedCountDownLatch.countDown()
            }
        case let .onPlayerError(error):
            handleError(error: error, isolation: isolation)
        case let .didChangePositionDiscontinuity(_, _, reason):
            discontinuityReasons.append(reason)
            let currentIndex = try #require(player).currentPeriodIndex
            if periodIndices.last != currentIndex { // TODO: check for ads
                // Ignore seek or internal discontinuities within a period.
                periodIndices.append(currentIndex)
            }
        default:
            return
        }
    }
}

extension SEPlayerTestRunner: ActionSchedule.Callback {
    func onActionScheduleFinished(isolation: isolated (any Actor)?) {
        actionScheduleFinishedCountDownLatch.countDown(isolation: isolation)
    }
}
