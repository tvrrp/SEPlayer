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
    let renderSynchronizer = AVSampleBufferRenderSynchronizer()
    let videoRenderer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()

    var nextState: SEPlayer.State?

    var mediaSource: MediaSource?
    var mediaPeriod: MediaPeriod?
    var sampleStreams: [SampleStream] = []

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

        renderSynchronizer.addRenderer(audioRenderer)
        renderSynchronizer.addRenderer(videoRenderer)
    }
}
