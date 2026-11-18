//
//  TestPlayerRunHelper.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import Testing
@testable import SEPlayer

/// Runs a player until something happens.
///
/// Tests using it run on the main actor: the player's commands go to its queue, and reading its
/// state waits for them. Events reach the main queue afterwards.
@MainActor
enum TestPlayerRunHelper {
    static let defaultTimeoutMs: UInt64 = 10_000

    /// Lets the player handle every command sent so far, and deliver the events they caused.
    static func runUntilPendingCommandsAreFullyHandled(_ player: SEPlayer) async {
        // The commands run on the playback queue in the order they were sent: a message sent now runs after them.
        await withCheckedContinuation { continuation in
            player.createMessage { _, _ in continuation.resume() }.send()
        }
        // What they changed reaches the player's queue, and its events the main queue.
        await withCheckedContinuation { continuation in
            playerSyncQueue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    /// `advance(player).untilState(state)`.
    static func advance(_ player: SEPlayer, untilState state: PlayerState, timeoutMs: UInt64 = defaultTimeoutMs) async throws {
        try await runUntil(player, timeoutMs: timeoutMs) { player.playbackState == state }
    }

    /// `advance(player).untilTimelineChanges()`.
    static func advanceUntilTimelineChanges(_ player: SEPlayer, timeoutMs: UInt64 = defaultTimeoutMs) async throws {
        let events = await PlayerDelegateAsyncStream(delegate: player.delegate)
        try await withTimeout(timeoutMs) {
            for await event in events.start() {
                if case .didChangeTimeline = event { return }
            }
        }
    }

    /// `play(player).untilPositionAtLeast(mediaItemIndex, positionMs)`: plays, and pauses once the
    /// media item plays at the position.
    static func play(
        _ player: SEPlayer,
        untilPositionAtLeastMs positionMs: Int64,
        mediaItemIndex: Int,
        timeoutMs: UInt64 = defaultTimeoutMs
    ) async throws {
        try await withTimeout(timeoutMs) {
            try await playUntilPosition(player: player, mediaItemIndex: mediaItemIndex, positionMs: positionMs)
        }
        await runUntilPendingCommandsAreFullyHandled(player)
    }

    /// Runs until `condition` holds, checking it after every event of the player.
    static func runUntil(
        _ player: SEPlayer,
        timeoutMs: UInt64 = defaultTimeoutMs,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let events = PlayerDelegateAsyncStream(delegate: player.delegate)
        await runUntilPendingCommandsAreFullyHandled(player)
        if condition() { return }
        try await withTimeout(timeoutMs) {
            for await _ in events.start() {
                if await condition() { return }
            }
            throw TimeoutError()
        }
    }
}

/// Plays until the media item plays at the position, then pauses.
///
/// Watched on the timebase the player plays on: the player itself has no timer to deliver a message
/// at a position. A boundary observer fires as playback passes the position. Its time is placed on the item as the
/// player knows it when the observer is added, which can be before the timeline is, so it is added again whenever the
/// periodic observer reports playback starting, stopping or jumping: its interval is longer than any test. That also
/// catches a position passed already.
func playUntilPosition(player: SEPlayer, mediaItemIndex: Int, positionMs: Int64) async throws {
    let target = CMTime(value: positionMs, timescale: 1000)
    let observerQueue = DispatchQueue(label: "PlayUntilPosition")
    let reachedPosition = AsyncStream<Void>.makeStream()
    // Used on observerQueue only.
    nonisolated(unsafe) var isWatching = true
    nonisolated(unsafe) var periodicObserver: AnyObject?
    nonisolated(unsafe) var boundaryObserver: AnyObject?

    nonisolated(unsafe) var check: (CMTime) -> Void = { _ in }
    func watchBoundary() throws {
        boundaryObserver.map(player.removeTimeObserver)
        boundaryObserver = try player.addBoundaryTimeObserver(for: [target], queue: observerQueue, block: check)
    }
    check = { _ in
        guard isWatching else { return }
        guard player.currentMediaItemIndex == mediaItemIndex, player.currentPosition >= target else {
            try? watchBoundary()
            return
        }
        isWatching = false
        player.pause()
        periodicObserver.map(player.removeTimeObserver)
        boundaryObserver.map(player.removeTimeObserver)
        reachedPosition.continuation.yield()
        reachedPosition.continuation.finish()
    }

    try observerQueue.sync {
        try watchBoundary()
        periodicObserver = try player.addPeriodicTimeObserver(
            for: CMTime(value: 3600, timescale: 1),
            queue: observerQueue,
            block: check
        )
    }

    player.play()
    for await _ in reachedPosition.stream { return }
}

/// Runs `body`, failing with `TimeoutError` once `timeoutMs` has passed.
func withTimeout<T: Sendable>(_ timeoutMs: UInt64, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Records what the player reports.
@MainActor
final class PlayerEventRecorder: SEPlayerDelegate {
    struct Discontinuity {
        let oldPosition: PositionInfo
        let newPosition: PositionInfo
        let reason: DiscontinuityReason
    }

    private(set) var discontinuities: [Discontinuity] = []
    private(set) var mediaItemTransitions: [(mediaItem: MediaItem?, reason: MediaItemTransitionReason?)] = []
    private(set) var isPlayingChanges: [Bool] = []
    private(set) var playbackStates: [PlayerState] = []

    init(player: SEPlayer) {
        player.delegate.addDelegate(self)
    }

    func seekDiscontinuities() -> [Discontinuity] {
        discontinuities.filter { $0.reason == .seek }
    }

    func player(_ player: Player, didChangePositionDiscontinuity oldPosition: PositionInfo, newPosition: PositionInfo, reason: DiscontinuityReason) {
        discontinuities.append(.init(oldPosition: oldPosition, newPosition: newPosition, reason: reason))
    }

    func player(_ player: Player, didTransitionMediaItem mediaItem: MediaItem?, reason: MediaItemTransitionReason?) {
        mediaItemTransitions.append((mediaItem, reason))
    }

    func player(_ player: Player, didChangeIsPlaying isPlaying: Bool) {
        isPlayingChanges.append(isPlaying)
    }

    func player(_ player: Player, didChangePlaybackState state: PlayerState) {
        playbackStates.append(state)
    }
}

extension CMTime {
    /// Milliseconds as positions are reported: the microseconds, truncated.
    var ms: Int64 { convertScale(1000, method: .roundTowardZero).value }
}
