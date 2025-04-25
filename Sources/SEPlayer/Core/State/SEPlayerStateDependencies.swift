//
//  SEPlayerStateDependencies.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFoundation

final class SEPlayerStateDependencies {
    let playerId: UUID
    let queue: Queue
    let returnQueue: Queue
    let sessionLoader: IPlayerSessionLoader
    let allocator: Allocator
    let allocator2: Allocator2
    let standaloneClock: DefaultMediaClock
    let clock: CMClock

    var mediaPeriodHolder: MediaPeriodHolder?

    var nextState: SEPlayer.State?

    var mediaSource: MediaSource?
    var mediaPeriod: MediaPeriod?
    var renderers: [BaseSERenderer] = []
    let newRenderers: [any SERenderer]

    let displayLink: DisplayLinkProvider
    let bufferableContainer: PlayerBufferableContainer

    init(
        queue: Queue,
        returnQueue: Queue,
        sessionLoader: IPlayerSessionLoader,
        playerId: UUID,
        allocator: Allocator,
        allocator2: Allocator2
    ) {
        self.queue = queue
        self.returnQueue = returnQueue
        self.sessionLoader = sessionLoader
        self.playerId = playerId
        self.allocator = allocator
        self.allocator2 = allocator2

        clock = CMClockGetHostTimeClock()
        displayLink = CADisplayLinkProvider(queue: queue)
        standaloneClock = DefaultMediaClock(clock: clock)
        bufferableContainer = PlayerBufferableContainer(displayLink: displayLink)

        newRenderers = [
            try? CAVideoRenderer<VideoToolboxDecoder>(
                queue: queue,
                clock: clock,
                displayLink: displayLink,
                bufferableContainer: bufferableContainer
            )
        ].compactMap { $0 }
    }
}
