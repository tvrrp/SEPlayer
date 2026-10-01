//
//  TestPlayerRunHelper.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import Testing
@testable import SEPlayer

/// Runs a player until something happens, after ExoPlayer's `TestPlayerRunHelper`.
///
/// Tests using it run on the main actor: the player's commands go to its queue, and reading its
/// state waits for them, as ExoPlayer's masking does. Events reach the main queue afterwards.
@MainActor
enum TestPlayerRunHelper {
    static let defaultTimeoutMs: UInt64 = 10_000

    /// Lets the player handle every command sent so far, and deliver the events they caused.
    static func runUntilPendingCommandsAreFullyHandled(_ player: SEPlayer) async {
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
/// at a position.
func playUntilPosition(player: SEPlayer, mediaItemIndex: Int, positionMs: Int64) async throws {
    let target = CMTime(value: positionMs, timescale: 1000)
    let observerQueue = DispatchQueue(label: "PlayUntilPosition")
    let reachedPosition = AsyncStream<Void>.makeStream()
    nonisolated(unsafe) var observer: AnyObject?
    observer = try player.addPeriodicTimeObserver(for: CMTime(value: 10, timescale: 1000), queue: observerQueue) { _ in
        guard observer != nil,
              player.currentMediaItemIndex == mediaItemIndex,
              player.currentPosition >= target else { return }
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        reachedPosition.continuation.yield()
        reachedPosition.continuation.finish()
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

/// Records what the player reports, as ExoPlayer's tests do with a mocked listener.
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
    /// Milliseconds as ExoPlayer reports positions: the microseconds, truncated (`Util.usToMs`).
    var ms: Int64 { convertScale(1000, method: .roundTowardZero).value }
}
