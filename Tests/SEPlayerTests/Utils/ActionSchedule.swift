//
//  ActionSchedule.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import Testing
@testable import SEPlayer

final class ActionSchedule {
    protocol Callback: AnyObject {
        func onActionScheduleFinished(isolation: isolated (any Actor)?)
    }

    private let rootNode: ActionNode
    private let callbackNode: CallbackAction

    fileprivate init(rootNode: ActionNode, callbackNode: CallbackAction) {
        self.rootNode = rootNode
        self.callbackNode = callbackNode
    }

    func start(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        callback: Callback?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        callbackNode.callback = callback
        try await rootNode.schedule(
            player: player,
            trackSelector: trackSelector,
            view: view,
            isolation: isolation
        )
    }

    final class Builder {
        private let tag: String
        private let rootNode: ActionNode
        private var currentDelayMs: UInt64 = .zero
        private var previousNode: ActionNode

        init(tag: String) {
            self.tag = tag
            rootNode = ActionNode(action: RootAction(tag: tag), delayMs: 0)
            previousNode = rootNode
        }

        @discardableResult
        func delay(_ delayMs: UInt64) -> Builder {
            currentDelayMs += delayMs
            return self
        }

        @discardableResult
        func apply(_ action: Action) -> Builder {
            appendActionNode(ActionNode(action: action, delayMs: currentDelayMs))
        }

        @discardableResult
        func repeatAction(_ action: Action, intervalMs: UInt64) -> Builder {
            appendActionNode(ActionNode(action: action, delayMs: currentDelayMs, repeatIntervalMs: intervalMs))
        }

        @discardableResult
        func seek(mediaItemIndex: Int? = nil, positionMs: Int64) -> Builder {
            apply(Seek(tag: tag, mediaItemIndex: mediaItemIndex, positionMs: positionMs))
        }

        @discardableResult
        func seekAndWait(positionMs: Int64) -> Builder {
            apply(Seek(tag: tag, positionMs: positionMs)).apply(
                WaitForPlayerDelegateState(
                    tag: tag,
                    checkForInitialState: { $0.playbackState == .ready },
                    validateEvent: { event in
                        if case let .didChangePlaybackState(state) = event {
                            return state == .ready
                        }
                        return false
                    }
                )
            )
        }

        @discardableResult
        func stop() -> Builder {
            apply(Stop(tag: tag))
        }

        @discardableResult
        func play() -> Builder {
            apply(SetPlayWhenReady(tag: tag, playWhenReady: true))
        }

        @discardableResult
        func pause() -> Builder {
            apply(SetPlayWhenReady(tag: tag, playWhenReady: false))
        }

        @discardableResult
        func waitForPlaybackState(_ state: PlayerState) -> Builder {
            apply(WaitForPlayerDelegateState(
                tag: tag,
                checkForInitialState: { $0.playbackState == .ready },
                validateEvent: {
                    if case let .didChangePlaybackState(state) = $0 {
                        return state == .ready
                    }
                    return false
                }
            ))
        }

        func build() -> ActionSchedule {
            let callbackAction = CallbackAction(tag: tag)
            apply(callbackAction)
            return ActionSchedule(rootNode: rootNode, callbackNode: callbackAction)
        }

        @discardableResult
        private func appendActionNode(_ actionNode: ActionNode) -> Builder {
            previousNode.setNext(actionNode)
            previousNode = actionNode
            currentDelayMs = 0
            return self
        }
    }
}

final class ActionNode {
    private let action: Action
    private let delayMs: UInt64
    private let repeatIntervalMs: UInt64?

    private var next: ActionNode?
    private var player: SEPlayer?
    private var trackSelector: DefaultTrackSelector?
    private var view: SEPlayerView?

    init(action: Action, delayMs: UInt64, repeatIntervalMs: UInt64? = nil) {
        self.action = action
        self.delayMs = delayMs
        self.repeatIntervalMs = repeatIntervalMs
    }

    func setNext(_ next: ActionNode, isolation: isolated (any Actor)? = #isolation) {
        self.next = next
    }

    func schedule(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        self.player = player
        self.trackSelector = trackSelector
        self.view = view

        if delayMs == 0 {
            try await run(isolation: isolation)
        } else {
            try await Task.sleep(milliseconds: delayMs)
            try await run(isolation: isolation)
        }
    }

    func run(isolation: isolated (any Actor)? = #isolation) async throws {
        try await action.doActionAndScheduleNext(
            player: try #require(player),
            trackSelector: try #require(trackSelector),
            view: view,
            nextAction: next,
            isolation: isolation
        )

        if let repeatIntervalMs {
            try await Task.sleep(milliseconds: repeatIntervalMs)
            try await action.doActionAndScheduleNext(
                player: try #require(player),
                trackSelector: try #require(trackSelector),
                view: view,
                nextAction: nil,
                isolation: isolation
            )
        }
    }
}

final class RootAction: Action {
    init(tag: String) { super.init(tag: tag, description: "Root") }

    override func doActionImpl(
        player: SEPlayer,
        trackSelector: DefaultTrackSelector,
        view: SEPlayerView?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {}
}

final class CallbackAction: Action {
    weak var callback: ActionSchedule.Callback?

    init(tag: String) { super.init(tag: tag, description: "Root") }

    override func doActionImpl(
        player: any SEPlayer,
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
        #expect(nextAction == nil)
        callback?.onActionScheduleFinished(isolation: isolation)
    }
}
