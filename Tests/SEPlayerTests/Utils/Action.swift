//
//  Action.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

@testable import SEPlayer
import Foundation

enum ActionErrors: Error {
    case unimplemented
}

class Action {
    private let tag: String
    private let description: String?

    init(tag: String, description: String? = nil) {
        self.tag = tag
        self.description = description ?? String(describing: Self.self)
    }

    func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        throw ActionErrors.unimplemented
    }

    final func doActionAndScheduleNext(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        if let description {
            print(description) // TODO: implement with logger
        }
        try await doActionAndScheduleNextImpl(
            player: player,
            trackSelector: trackSelector,
            view: view,
            nextAction: nextAction,
            isolation: isolation
        )
    }

    func doActionAndScheduleNextImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await doActionImpl(player: player, trackSelector: trackSelector, view: view, isolation: isolation)
        if let nextAction {
            try await nextAction.schedule(
                player: player,
                trackSelector: trackSelector,
                view: view,
                isolation: isolation
            )
        }
    }
}

final class Seek: Action {
    private let mediaItemIndex: Int?
    private let positionMs: Int64

    init(tag: String, mediaItemIndex: Int? = nil, positionMs: Int64) {
        self.mediaItemIndex = mediaItemIndex
        self.positionMs = positionMs
        super.init(tag: tag, description: "Seek \(positionMs)")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        if let mediaItemIndex {
            player.seek(to: positionMs, of: mediaItemIndex)
        } else {
            player.seek(to: positionMs)
        }
    }
}

final class SetMediaItems: Action {
    private let mediaItemIndex: Int
    private let positionMs: Int64
    private let mediaSources: [MediaSource]

    init(tag: String, mediaItemIndex: Int, positionMs: Int64, mediaSources: [MediaSource]) {
        self.mediaItemIndex = mediaItemIndex
        self.positionMs = positionMs
        self.mediaSources = mediaSources
        super.init(tag: tag)
    }

    override func doActionImpl(player: any SEPlayer, trackSelector: DefaultTrackSelector, view: SEPlayerView?, isolation: isolated (any Actor)? = #isolation) async throws {
        player.set(mediaSources: mediaSources, startMediaItemIndex: mediaItemIndex, startPositionMs: positionMs)
    }
}

final class AddMediaItems: Action {
    private let mediaSources: [MediaSource]

    init(tag: String, mediaSources: [MediaSource]) {
        self.mediaSources = mediaSources
        super.init(tag: tag)
    }

    override func doActionImpl(player: any SEPlayer, trackSelector: DefaultTrackSelector, view: SEPlayerView?, isolation: isolated (any Actor)? = #isolation) async throws {
        player.append(mediaSources: mediaSources)
    }
}

final class Stop: Action {
    init(tag: String) {
        super.init(tag: tag)
    }

    override func doActionImpl(player: any SEPlayer, trackSelector: DefaultTrackSelector, view: SEPlayerView?, isolation: isolated (any Actor)? = #isolation) async throws {
        player.stop()
    }
}

final class SetPlayWhenReady: Action {
    private let playWhenReady: Bool

    init(tag: String, playWhenReady: Bool) {
        self.playWhenReady = playWhenReady
        super.init(tag: tag)
    }

    override func doActionImpl(player: any SEPlayer, trackSelector: DefaultTrackSelector, view: SEPlayerView?, isolation: isolated (any Actor)? = #isolation) async throws {
        player.playWhenReady = playWhenReady
    }
}

final class WaitForPlayerDelegateState: Action {
    private let checkForInitialState: (PlayerState) -> Bool
    private let validateEvent: (PlayerDelegateAsyncStream.Event) -> Bool

    init(
        tag: String,
        checkForInitialState: @escaping (PlayerState) -> Bool,
        validateEvent: @escaping (PlayerDelegateAsyncStream.Event) -> Bool
    ) {
        self.checkForInitialState = checkForInitialState
        self.validateEvent = validateEvent
        super.init(tag: tag, description: "WaitForPlaybackState")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {}

    override func doActionAndScheduleNextImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        guard let nextAction else { return }

        if checkForInitialState(player.playbackState) == false {
            let playerEventListener = await PlayerDelegateAsyncStream(delegate: player.delegate)
            for await event in playerEventListener.start() {
                if validateEvent(event) { break }
            }
        }

        try await nextAction.schedule(
            player: player,
            trackSelector: trackSelector,
            view: view,
            isolation: isolation
        )
    }
}

final class PlayUntilPosition: Action {
    private let mediaItemIndex: Int
    private let positionMs: Int64

    init(tag: String, mediaItemIndex: Int, positionMs: Int64) {
        self.mediaItemIndex = mediaItemIndex
        self.positionMs = positionMs
        super.init(tag: tag, description: "PlayUntilPosition:\(mediaItemIndex):\(positionMs)")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {}

    override func doActionAndScheduleNextImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        let mainQueue = Queues.mainQueue
        player
            .createMessage { _, _ in
                await MainActor.run { player.pause() }
                print("❌ RUNNING PAUSE, curr = \(player.currentPosition)")
            }
            .setPositionMs(positionMs, mediaItemIndex: mediaItemIndex)
            .send()

        struct Box { var continuation: CheckedContinuation<Void, Never>? }
        var box = Box(continuation: nil)

        if nextAction != nil {
            player.createMessage { _, _ in
                box.continuation?.resume()
            }
            .setPositionMs(positionMs, mediaItemIndex: mediaItemIndex)
            .setQueue(mainQueue)
            .send()
        }

        player.play()
        if let nextAction {
            await withCheckedContinuation { continuation in
                box.continuation = continuation
            }
            try await nextAction.schedule(player: player, trackSelector: trackSelector, view: view)
        }
    }
}

final class WaitForTimelineChanged: Action {
    private let expectedTimeline: Timeline?
    private let ignoreExpectedReason: Bool
    private let expectedReason: TimelineChangeReason

    init(tag: String) {
        expectedTimeline = nil
        ignoreExpectedReason = true
        expectedReason = .playlistChanged
        super.init(tag: tag, description: "WaitForTimelineChanged")
    }

    init(tag: String, expectedTimeline: Timeline, expectedReason: TimelineChangeReason) {
        self.expectedTimeline = expectedTimeline
        ignoreExpectedReason = false
        self.expectedReason = expectedReason
        super.init(tag: tag, description: "WaitForTimelineChanged")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {}

    override func doActionAndScheduleNextImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        guard let nextAction else { return }
        let playerEventListener = await PlayerDelegateAsyncStream(delegate: player.delegate)

        if let expectedTimeline,
           TestUtil.timelinesAreSame(lhs: expectedTimeline, rhs: player.timeline) {
            try await nextAction.schedule(player: player, trackSelector: trackSelector, view: view)
            return
        }

        print("❌ Will start listening")
        for await event in playerEventListener.start() {
            print("❌ event = \(event)")
            if case let .didChangeTimeline(timeline, reason) = event {
                print("❌ didChangeTimeline, reason = \(reason)")
                print("❌ \(timeline)")
                let timelineMatches = expectedTimeline.map {
                    TestUtil.timelinesAreSame(lhs: timeline, rhs: $0)
                } ?? true

                if timelineMatches && (ignoreExpectedReason || expectedReason == reason) {
                    try await nextAction.schedule(player: player, trackSelector: trackSelector, view: view)
                    return
                }
            }
        }
    }
}

final class WaitForPendingPlayerCommands: Action {
    init(tag: String) {
        super.init(tag: tag, description: "WaitForPendingPlayerCommands")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {}

    override func doActionAndScheduleNextImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        nextAction: ActionNode?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        guard let nextAction else {
            return
        }

        await withCheckedContinuation { continuation in
            player
                .createMessage { _, _ in
                    continuation.resume()
                }
                .send()
        }

        try await nextAction.schedule(player: player, trackSelector: trackSelector, view: view)
    }
}

final class ExecuteClosure: Action {
    private let closure: ((SEPlayer) async throws -> Void)

    init(
        tag: String,
        closure: @escaping (SEPlayer) async throws -> Void
    ) {
        self.closure = closure
        super.init(tag: tag, description: "ExecuteClosure")
    }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await closure(player)
    }
}
