//
//  Action.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

@testable import SEPlayer

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
    private let checkForInitialState: (SEPlayer) -> Bool
    private let validateEvent: (PlayerDelegateAsyncStream.Event) -> Bool

    init(
        tag: String,
        checkForInitialState: @escaping (SEPlayer) -> Bool,
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

        if checkForInitialState(player) == false {
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
