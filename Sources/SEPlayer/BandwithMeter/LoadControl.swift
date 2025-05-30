//
//  LoadControl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.05.2025.
//

import Foundation.NSUUID

public protocol LoadControl {
    func onPrepared(playerId: UUID)
    func onTracksSelected(parameters: LoadControlParams, trackGroups: [TrackGroup], trackSelections: [SETrackSelection?])
    func onStopped(playerId: UUID)
    func onReleased(playerId: UUID)
    func getAllocator() -> Allocator
    func getBackBufferDurationUs(playerId: UUID) -> Int64
    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool
    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool
    func shouldContinuePreloading(timeline: Timeline, mediaPeriodId: MediaPeriodId, bufferedDurationUs: Int64) -> Bool
    func shouldStartPlayback(parameters: LoadControlParams) -> Bool
}

public struct LoadControlParams {
    let playerId: UUID
    let timeline: Timeline
    let mediaPeriodId: MediaPeriodId
    let playbackPositionUs: Int64
    let bufferedDurationUs: Int64
    let playbackSpeed: Float
    let playWhenReady: Bool
    let rebuffering: Bool
    let targetLiveOffsetUs: Int64
    let lastRebufferRealtimeMs: Int64
}

struct DefaultLoadControl: LoadControl {
    private let queue: Queue
    private let allocator: Allocator

    private let minBufferUs: Int64
    private let maxBufferUs: Int64
    private let bufferForPlaybackUs: Int64
    private let bufferForPlaybackAfterRebufferUs: Int64
    private let backBufferDurationUs: Int64
    private let retainBackBufferFromKeyframe: Bool

    init(
        queue: Queue,
        allocator: Allocator? = nil,
        minBufferMs: Int64 = DefaultConstants.minBufferMs,
        maxBufferMs: Int64 = DefaultConstants.maxBufferMs,
        bufferForPlaybackMs: Int64 = DefaultConstants.bufferForPlaybackMs,
        bufferForPlaybackAfterRebufferMs: Int64 = DefaultConstants.bufferForPlaybackAfterRebuffer,
        backBufferDurationMs: Int64 = DefaultConstants.backBufferDurationMs,
        retainBackBufferFromKeyframe: Bool = DefaultConstants.retainBackBufferFromKeyframe
    ) {
        self.queue = queue
        self.allocator = allocator ?? DefaultAllocator(queue: queue)

        self.minBufferUs = Time.msToUs(timeMs: minBufferMs)
        self.maxBufferUs = Time.msToUs(timeMs: maxBufferMs)
        self.bufferForPlaybackUs = Time.msToUs(timeMs: bufferForPlaybackMs)
        self.bufferForPlaybackAfterRebufferUs = Time.msToUs(timeMs: bufferForPlaybackAfterRebufferMs)
        self.backBufferDurationUs = Time.msToUs(timeMs: backBufferDurationMs)
        self.retainBackBufferFromKeyframe = retainBackBufferFromKeyframe
    }

    func onPrepared(playerId: UUID) {
        assertQueue()
    }

    func onTracksSelected(
        parameters: LoadControlParams,
        trackGroups: [TrackGroup],
        trackSelections: [SETrackSelection?]
    ) {
        assertQueue()
    }

    func onStopped(playerId: UUID) {
        assertQueue()
    }

    func onReleased(playerId: UUID) {
        assertQueue()
    }

    func getAllocator() -> Allocator {
        assertQueue()
        return allocator
    }

    func getBackBufferDurationUs(playerId: UUID) -> Int64 {
        return .zero
    }

    func retainBackBufferFromKeyframe(playerId: UUID) -> Bool {
        return true
    }

    func shouldContinueLoading(with parameters: LoadControlParams) -> Bool {
        assertQueue()
        return true
    }

    func shouldContinuePreloading(
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDurationUs: Int64
    ) -> Bool {
        assertQueue()
        return false
    }

//    func shouldStartPlayback(parameters: LoadControlParams) -> Bool {
//        assertQueue()
//        return parameters.playWhenReady && parameters.bufferedDurationUs > Time.msToUs(timeMs: 1000)
//    }

    func shouldStartPlayback(parameters: LoadControlParams) -> Bool {
        assertQueue()
        let bufferedDurationUs = AudioUtils.mediaDurationFor(
            playoutDuration: parameters.bufferedDurationUs,
            speed: parameters.playbackSpeed
        )

        let minBufferDurationUs = parameters.rebuffering ? bufferForPlaybackAfterRebufferUs : bufferForPlaybackUs

        return minBufferDurationUs <= 0 || bufferedDurationUs >= minBufferDurationUs
    }

    private func assertQueue() {
        #if DEBUG
        if !queue.isCurrent() {
            assertionFailure("Players that share the same LoadControl must also share the same WorkQueue")
        }
        #endif
    }
}

extension DefaultLoadControl {
    public enum DefaultConstants {
        static let minBufferMs: Int64 = 50_000
        static let maxBufferMs: Int64 = 50_000
        static let bufferForPlaybackMs: Int64 = 1000
        static let bufferForPlaybackAfterRebuffer: Int64 = 2000
        static let backBufferDurationMs: Int64 = 1000
        static let retainBackBufferFromKeyframe: Bool = true
    }
}
