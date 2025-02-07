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
    let standaloneClock: StandaloneClock
    let clock: CMClock

    var mediaPeriodHolder: MediaPeriodHolder?

    var nextState: SEPlayer.State?

    var mediaSource: MediaSource?
    var mediaPeriod: MediaPeriod?
    var renderers: [BaseSERenderer] = []
    
    let displayLink: DisplayLinkProvider
    let audioRenderer: AVSampleBufferAudioRenderer
    let renderSynchronizer: AVSampleBufferRenderSynchronizer

    init(
        queue: Queue,
        returnQueue: Queue,
        sessionLoader: IPlayerSessionLoader,
        playerId: UUID,
        allocator: Allocator
    ) {
        self.queue = queue
        self.returnQueue = returnQueue
        self.sessionLoader = sessionLoader
        self.playerId = playerId
        self.allocator = allocator

        var clock: CMClock!
        CMAudioClockCreate(allocator: nil, clockOut: &clock)
        self.clock = clock
        self.displayLink = CADisplayLinkProvider(queue: queue)
        renderSynchronizer = AVSampleBufferRenderSynchronizer()
        audioRenderer = AVSampleBufferAudioRenderer()
        renderSynchronizer.addRenderer(audioRenderer)
//        self.standaloneClock = StandaloneClock(clock: clock)
        self.standaloneClock = StandaloneClock(renderSynchronizer: renderSynchronizer)
    }
}
