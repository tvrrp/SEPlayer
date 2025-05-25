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
    let allocator: Allocator
    var renderers: [SERenderer] = []
    let standaloneClock: DefaultMediaClock
    let clock: CMClock

    var mediaPeriodHolder: MediaPeriodHolder?

    var mediaSource: MediaSource?
    var mediaPeriod: MediaPeriod?

    let bufferableContainer: PlayerBufferableContainer
    let mediaSourceList: MediaSourceList

    init(
        playerId: UUID,
        queue: Queue,
        clock: CMClock,
        allocator: Allocator,
        bufferableContainer: PlayerBufferableContainer
    ) {
        self.playerId = playerId
        self.queue = queue
        self.allocator = allocator
        self.clock = clock
        self.bufferableContainer = bufferableContainer
        mediaSourceList = MediaSourceList(playerId: playerId)

        standaloneClock = DefaultMediaClock(clock: clock)
    }
}
