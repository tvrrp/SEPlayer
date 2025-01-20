//
//  SEPlayerBaseState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

class SEPlayerBaseState: SEPlayerState {
    weak var statable: (any SEPlayerStatable)?

    var state: SEPlayer.State { fatalError("not implemented") }
    let dependencies: SEPlayerStateDependencies

    var mediaSource: MediaSource? {
        dependencies.mediaSource
    }

    var queue: Queue {
        dependencies.queue
    }

    init(dependencies: SEPlayerStateDependencies, statable: (any SEPlayerStatable)?) {
        self.dependencies = dependencies
        self.statable = statable
    }

    func didLoad() {
        assert(queue.isCurrent())
    }

    func prepare() {
        assert(queue.isCurrent())
        if let mediaSource, let statable {
            mediaSource.prepareSource(
                delegate: statable, mediaTransferListener: nil, playerId: dependencies.playerId
            )
            dependencies.mediaPeriod = mediaSource.createPeriod(
                id: .init(periodId: UUID(), windowSequenceNumber: 0),
                allocator: dependencies.allocator,
                startPosition: .zero,
                loadCondition: statable,
                mediaSourceEventDelegate: statable
            )
            dependencies.mediaPeriod?.prepare(callback: statable, on: .zero)
        }
    }

    func performNext(_ next: SEPlayer.State) {
        
    }

    func idle() {
        assert(queue.isCurrent())
//        let state = SEPlayerIdleState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func play() {
        assert(queue.isCurrent())
        let state = SEPlayerPlayingState(dependencies: dependencies, statable: statable)
        statable?.perform(state)
    }

    func stall() {
        assert(queue.isCurrent())
//        let state = SEPlayerStalledState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func pause() {
        assert(queue.isCurrent())
//        let state = SEPlayerPausedState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func ready() {
        assert(queue.isCurrent())
//        let state = SEPlayerReadyState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func seek(to time: Double, completion: (() -> Void)?) {
        assert(queue.isCurrent())
//        let state = SEPlayerSeekingState(dependencies: dependencies, time: time, completion: completion, statable: statable)
//        statable?.perform(state)
    }

    func loading() {
        assert(queue.isCurrent())
//        let state = SEPlayerLoadingState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func end() {
        assert(queue.isCurrent())
//        let state = SEPlayerEndedState(dependencies: dependencies, statable: statable)
//        statable?.perform(state)
    }

    func error(_ error: Error?) {
        assert(queue.isCurrent())
//        let state = SEPlayerErrorState(dependencies: dependencies, error: error, statable: statable)
//        statable?.perform(state)
    }
}
