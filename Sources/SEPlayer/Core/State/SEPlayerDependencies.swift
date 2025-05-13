//
//  SEPlayerStateDependencies.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFoundation

final class SEPlayerDependencies {
    let playerId: UUID
    let queue: Queue
    let returnQueue: Queue
    let sessionLoader: IPlayerSessionLoader
    let allocator: Allocator
    var renderers: [SERenderer] = []
    let standaloneClock: DefaultMediaClock
    let clock: CMClock

    var mediaPeriodHolder: MediaPeriodHolder?

    var nextState: SEPlayer.State?

    var mediaSource: MediaSource?
    var mediaPeriod: MediaPeriod?

    let displayLink: DisplayLinkProvider
    let bufferableContainer: PlayerBufferableContainer

    init(
        playerId: UUID,
        queue: Queue,
        returnQueue: Queue,
        sessionLoader: IPlayerSessionLoader,
        allocator: Allocator,
        displayLink: DisplayLinkProvider
    ) {
        self.playerId = playerId
        self.queue = queue
        self.returnQueue = returnQueue
        self.sessionLoader = sessionLoader
        self.allocator = allocator
        self.clock = CMClockGetHostTimeClock()
        self.displayLink = displayLink
        self.bufferableContainer = PlayerBufferableContainer(displayLink: displayLink)

        standaloneClock = DefaultMediaClock(clock: clock)
    }
}
