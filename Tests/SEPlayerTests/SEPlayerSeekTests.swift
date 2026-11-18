//
//  SEPlayerSeekTests.swift
//  SEPlayer
//
//  Seeking tests, driving the player directly.
//

import CoreMedia
import Foundation
import Testing
@testable import SEPlayer

/// Every player in these tests plays on the same queue, so they run one at a time.
@Suite(.serialized)
@MainActor
final class SEPlayerSeekTests {
    private typealias Helper = TestPlayerRunHelper

    /// `C.DEFAULT_SEEK_BACK_INCREMENT_MS` and `C.DEFAULT_SEEK_FORWARD_INCREMENT_MS`, which the test
    /// player is built with.
    private let seekBackIncrementMs: Int64 = 5000
    private let seekForwardIncrementMs: Int64 = 15000

    // MARK: - seekTo

    @Test
    func `seekTo indexLargerThanPlaylist isIgnored`() async throws {
        let player = try TestSEPlayerFactory().build()
        player.set(mediaSource: try FakeMediaSource())

        player.seek(to: ms(1000), of: 1)

        #expect(player.currentMediaItemIndex == 0)
        player.release()
    }

    @Test
    func `seekTo withEmptyTimeline emitsPositionDiscontinuityEvent`() async throws {
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)

        player.seek(to: ms(2000))
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(recorder.seekDiscontinuities().count == 1)
        player.release()
    }

    @Test
    func `seekTo callsOnPositionDiscontinuity`() async throws {
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)
        player.set(mediaSources: [try createFakeMediaSource(id: "id-0"), try createFakeMediaSource(id: "id-1")])

        player.prepare()
        try await Helper.play(player, untilPositionAtLeastMs: 5000, mediaItemIndex: 0)
        player.seek(to: ms(7000))
        player.seek(to: ms(1000), of: 1)
        player.play()
        try await Helper.advance(player, untilState: .ended)

        #expect(recorder.discontinuities.allSatisfy { $0.reason == .seek })
        let seeks = recorder.seekDiscontinuities()
        try #require(seeks.count == 2)
        #expect(seeks[0].oldPosition.windowId == seeks[0].newPosition.windowId)
        #expect(seeks[0].newPosition.mediaItemIndex == 0)
        #expect(seeks[0].newPosition.mediaItem?.localConfiguration?.tag == AnyHashable("id-0"))
        #expect(isAroundPosition(seeks[0].oldPosition.position.ms, 5000))
        #expect(isAroundPosition(seeks[0].oldPosition.contentPosition.ms, 5000))
        #expect(seeks[0].oldPosition.mediaItemIndex == 0)
        #expect(seeks[0].oldPosition.mediaItem?.localConfiguration?.tag == AnyHashable("id-0"))
        #expect(seeks[0].newPosition.position.ms == 7000)
        #expect(seeks[0].newPosition.contentPosition.ms == 7000)
        #expect(seeks[1].oldPosition.windowId != seeks[1].newPosition.windowId)
        #expect(seeks[1].oldPosition.mediaItemIndex == 0)
        #expect(seeks[1].oldPosition.mediaItem?.localConfiguration?.tag == AnyHashable("id-0"))
        #expect(seeks[1].oldPosition.position.ms == 7000)
        #expect(seeks[1].oldPosition.contentPosition.ms == 7000)
        #expect(seeks[1].newPosition.mediaItemIndex == 1)
        #expect(seeks[1].newPosition.mediaItem?.localConfiguration?.tag == AnyHashable("id-1"))
        #expect(seeks[1].newPosition.position.ms == 1000)
        #expect(seeks[1].newPosition.contentPosition.ms == 1000)
        player.release()
    }

    @Test
    func `seekTo whenTimelineEmpty callsOnPositionDiscontinuityAndSetsCorrectIndices`() async throws {
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)

        let mediaItemIndex0 = player.currentMediaItemIndex
        let periodIndex0 = player.currentPeriodIndex
        player.seek(to: ms(7000))
        let mediaItemIndex1 = player.currentMediaItemIndex
        let periodIndex1 = player.currentPeriodIndex
        player.seek(to: ms(1000), of: 1)
        let mediaItemIndex2 = player.currentMediaItemIndex
        let periodIndex2 = player.currentPeriodIndex
        player.seek(to: ms(5000))
        let mediaItemIndex3 = player.currentMediaItemIndex
        let periodIndex3 = player.currentPeriodIndex
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(mediaItemIndex0 == 0)
        #expect(periodIndex0 == 0)
        #expect(mediaItemIndex1 == 0)
        #expect(periodIndex1 == 0)
        #expect(mediaItemIndex2 == 1)
        #expect(periodIndex2 == 1)
        #expect(mediaItemIndex3 == 1)
        #expect(periodIndex3 == 1)
        #expect(recorder.discontinuities.allSatisfy { $0.reason == .seek })
        let seeks = recorder.seekDiscontinuities()
        try #require(seeks.count == 3)
        // A seek from the initial state to a masked seek position.
        #expect(seeks[0].oldPosition.windowId == nil)
        #expect(seeks[0].oldPosition.mediaItemIndex == 0)
        #expect(seeks[0].oldPosition.periodIndex == 0)
        #expect(seeks[0].oldPosition.mediaItem == nil)
        #expect(seeks[0].oldPosition.position.ms == 0)
        #expect(seeks[0].oldPosition.contentPosition.ms == 0)
        #expect(seeks[0].newPosition.mediaItemIndex == 0)
        #expect(seeks[0].newPosition.periodIndex == 0)
        #expect(seeks[0].newPosition.windowId == nil)
        #expect(seeks[0].newPosition.position.ms == 7000)
        #expect(seeks[0].newPosition.contentPosition.ms == 7000)
        // A seek from a masked seek position to another masked position across windows.
        #expect(seeks[1].oldPosition.windowId == nil)
        #expect(seeks[1].oldPosition.mediaItemIndex == 0)
        #expect(seeks[1].oldPosition.periodIndex == 0)
        #expect(seeks[1].oldPosition.mediaItem == nil)
        #expect(seeks[1].oldPosition.position.ms == 7000)
        #expect(seeks[1].oldPosition.contentPosition.ms == 7000)
        #expect(seeks[1].newPosition.windowId == nil)
        #expect(seeks[1].newPosition.mediaItemIndex == 1)
        #expect(seeks[1].newPosition.periodIndex == 1)
        #expect(seeks[1].newPosition.position.ms == 1000)
        #expect(seeks[1].newPosition.contentPosition.ms == 1000)
        // A seek from a masked seek position to another masked position within the media item.
        #expect(seeks[2].oldPosition.windowId == nil)
        #expect(seeks[2].oldPosition.mediaItemIndex == 1)
        #expect(seeks[2].oldPosition.periodIndex == 1)
        #expect(seeks[2].oldPosition.mediaItem == nil)
        #expect(seeks[2].oldPosition.position.ms == 1000)
        #expect(seeks[2].oldPosition.contentPosition.ms == 1000)
        #expect(seeks[2].newPosition.windowId == nil)
        #expect(seeks[2].newPosition.mediaItemIndex == 1)
        #expect(seeks[2].newPosition.periodIndex == 1)
        #expect(seeks[2].newPosition.position.ms == 5000)
        #expect(seeks[2].newPosition.contentPosition.ms == 5000)
        player.release()
    }

    @Test
    func `seekTo otherWindow notifiesMediaItemTransition`() async throws {
        let mediaSource1 = try createFakeMediaSource(id: UUID())
        let mediaSource2 = try createFakeMediaSource(id: UUID())
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)
        player.set(mediaSources: [mediaSource1, mediaSource2])
        player.prepare()
        try await Helper.advance(player, untilState: .ready)

        player.seek(to: ms(2000), of: 1)
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(recorder.mediaItemTransitions.map(\.mediaItem) == [mediaSource1.getMediaItem(), mediaSource2.getMediaItem()])
        #expect(recorder.mediaItemTransitions.map(\.reason) == [.playlistChanged, .seek])
        player.release()
    }

    @Test
    func `seekTo sameWindow doesNotNotifyMediaItemTransition`() async throws {
        let mediaSource1 = try createFakeMediaSource(id: UUID())
        let mediaSource2 = try createFakeMediaSource(id: UUID())
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)
        player.set(mediaSources: [mediaSource1, mediaSource2])
        player.prepare()
        try await Helper.advance(player, untilState: .ready)

        player.seek(to: ms(2000), of: 0)
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(recorder.mediaItemTransitions.map(\.mediaItem) == [mediaSource1.getMediaItem()])
        #expect(recorder.mediaItemTransitions.map(\.reason) == [.playlistChanged])
        player.release()
    }

    @Test
    func `seekToIndexLargerThanNumberOfPlaylistItems`() async throws {
        let timeline = FakeTimeline()
        let player = try TestSEPlayerFactory().build()
        player.seek(to: ms(5000), of: 1)
        // A playlist of the two sources is the same timeline as the two concatenated.
        player.set(
            mediaSources: [
                try FakeMediaSource(timeline: timeline, formats: [SEPlayerTestRunner.videoFormat]),
                try FakeMediaSource(timeline: timeline, formats: [SEPlayerTestRunner.videoFormat]),
            ],
            resetPosition: false
        )
        player.prepare()

        try await Helper.advanceUntilTimelineChanges(player)
        let currentMediaItemIndex = player.currentMediaItemIndex
        let currentPlaybackPositionMs = player.currentPosition.ms
        player.release()

        #expect(currentMediaItemIndex == 1)
        #expect(currentPlaybackPositionMs == 5000)
    }

    // MARK: - seekBack / seekForward

    @Test
    func `seekBack callsOnPositionDiscontinuity`() async throws {
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)
        let timeline = FakeTimeline(windowDefinitions: [
            .init(isDynamic: true, durationUs: Time.msToUs(timeMs: 3 * seekBackIncrementMs))
        ])
        player.set(mediaSource: try FakeMediaSource(timeline: timeline))

        player.prepare()
        try await Helper.play(player, untilPositionAtLeastMs: 2 * seekBackIncrementMs, mediaItemIndex: 0)
        player.seekBack()
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(recorder.discontinuities.allSatisfy { $0.reason == .seek })
        let seeks = recorder.seekDiscontinuities()
        try #require(seeks.count == 1)
        #expect(seeks[0].oldPosition.mediaItemIndex == 0)
        #expect(isAroundPosition(seeks[0].oldPosition.position.ms, 2 * seekBackIncrementMs))
        #expect(isAroundPosition(seeks[0].oldPosition.contentPosition.ms, 2 * seekBackIncrementMs))
        #expect(seeks[0].newPosition.mediaItemIndex == 0)
        #expect(isAroundPosition(seeks[0].newPosition.position.ms, seekBackIncrementMs))
        #expect(isAroundPosition(seeks[0].newPosition.contentPosition.ms, seekBackIncrementMs))
        player.release()
    }

    @Test
    func `seekBack pastZero seeksToZero`() async throws {
        let player = try TestSEPlayerFactory().build()
        let timeline = FakeTimeline(windowDefinitions: [
            .init(isDynamic: true, durationUs: Time.msToUs(timeMs: seekBackIncrementMs))
        ])
        player.set(mediaSource: try FakeMediaSource(timeline: timeline))

        player.prepare()
        try await Helper.play(player, untilPositionAtLeastMs: seekBackIncrementMs / 2, mediaItemIndex: 0)
        player.seekBack()

        #expect(player.currentPosition.ms == 0)
        player.release()
    }

    @Test
    func `seekForward callsOnPositionDiscontinuity`() async throws {
        let player = try TestSEPlayerFactory().build()
        let recorder = PlayerEventRecorder(player: player)
        let timeline = FakeTimeline(windowDefinitions: [
            .init(isDynamic: true, durationUs: Time.msToUs(timeMs: 2 * seekForwardIncrementMs))
        ])
        player.set(mediaSource: try FakeMediaSource(timeline: timeline))

        player.prepare()
        try await Helper.advance(player, untilState: .ready)
        player.seekForward()
        await Helper.runUntilPendingCommandsAreFullyHandled(player)

        #expect(recorder.discontinuities.allSatisfy { $0.reason == .seek })
        let seeks = recorder.seekDiscontinuities()
        try #require(seeks.count == 1)
        #expect(seeks[0].oldPosition.mediaItemIndex == 0)
        #expect(seeks[0].oldPosition.position.ms == 0)
        #expect(seeks[0].oldPosition.contentPosition.ms == 0)
        #expect(seeks[0].newPosition.mediaItemIndex == 0)
        #expect(seeks[0].newPosition.position.ms == seekForwardIncrementMs)
        #expect(seeks[0].newPosition.contentPosition.ms == seekForwardIncrementMs)
        player.release()
    }

    @Test
    func `seekForward pastDuration seeksToDuration`() async throws {
        let player = try TestSEPlayerFactory().build()
        let timeline = FakeTimeline(windowDefinitions: [
            .init(isDynamic: true, durationUs: Time.msToUs(timeMs: seekForwardIncrementMs / 2))
        ])
        player.set(mediaSource: try FakeMediaSource(timeline: timeline))

        player.prepare()
        try await Helper.advance(player, untilState: .ready)
        player.seekForward()

        #expect(player.currentPosition.ms == seekForwardIncrementMs / 2 - 1)
        player.release()
    }

    // MARK: - seekToPrevious / seekToNext

    @Test
    func `seekToPrevious withPreviousWindowAndCloseToStart seeksToPreviousWindow`() async throws {
        let player = try TestSEPlayerFactory().setMaxSeekToPreviousPositionMs(10_000).build()
        player.append(mediaSources: [try FakeMediaSource(), try FakeMediaSource()])
        player.seek(to: ms(10_000), of: 1)

        player.seekToPrevious()

        #expect(player.currentMediaItemIndex == 0)
        #expect(player.currentPosition.ms == 0)
        player.release()
    }

    @Test
    func `seekToPrevious notCloseToStart seeksToZero`() async throws {
        let player = try TestSEPlayerFactory().setMaxSeekToPreviousPositionMs(10_000).build()
        player.append(mediaSources: [try FakeMediaSource(), try FakeMediaSource()])
        player.seek(to: ms(10_001), of: 1)

        player.seekToPrevious()

        #expect(player.currentMediaItemIndex == 1)
        #expect(player.currentPosition.ms == 0)
        player.release()
    }

    @Test
    func `seekToNext withNextWindow seeksToNextWindow`() async throws {
        let player = try TestSEPlayerFactory().build()
        player.append(mediaSources: [try FakeMediaSource(), try FakeMediaSource()])

        player.seekToNext()

        #expect(player.currentMediaItemIndex == 1)
        #expect(player.currentPosition.ms == 0)
        player.release()
    }

    // MARK: - Helpers

    private func ms(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: 1000)
    }

    /// A timeline with one window of that id.
    private func createFakeMediaSource(id: AnyHashable) throws -> FakeMediaSource {
        try FakeMediaSource(timeline: FakeTimeline(windowDefinitions: [.init(id: id)]))
    }

    /// Positions reached by playing are checked within 20ms before the position, as the
    /// position lags its clock. Here playback is paused on the timebase once the position is
    /// reached, so it stops after it: by as much, plus what a couple of milliseconds of real time
    /// to get the pause through come to on the sped-up media time of the tests.
    private func isAroundPosition(_ positionMs: Int64, _ expectedMs: Int64) -> Bool {
        let lateMs = 20 + Int64(2 * FakeClock.mediaTimeRate)
        return (expectedMs - 20...expectedMs + lateMs).contains(positionMs)
    }
}
