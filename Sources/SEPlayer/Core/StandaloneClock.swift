//
//  StandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import AVFoundation

//final class StandaloneClock {
//    private let clock: CMClock
//
//    private var playbackRate: Float = 1.0
//    private var started: Bool = false
//    private var baseElapsed: Int64 = 0
//    private var baseTime: Int64 = 0
//
//    init(clock: CMClock) {
//        self.clock = clock
//    }
//
//    func start() {
//        guard !started else { return }
//        baseElapsed = clock.microseconds
//        started = true
//    }
//
//    func stop() {
//        guard started else { return }
//        started = false
//    }
//
//    func resetPosition(position: Int64) {
//        baseTime = position
//        if started {
//            baseElapsed = clock.microseconds
//        }
//    }
//
//    func getPosition() ->Int64  {
//        var position = baseTime
//        if started {
//            let elapsedSinceBase = clock.microseconds - baseElapsed
//            position += Int64(Double(elapsedSinceBase) * Double(playbackRate))
//        }
//
//        return position
//    }
//
//    func setPlaybackRate(new playbackRate: Float) {
//        guard self.playbackRate != playbackRate else { return }
//        self.playbackRate = playbackRate
//    }
//}

final class StandaloneClock {
    private let renderSynchronizer: AVSampleBufferRenderSynchronizer

    private var playbackRate: Float = 1.0
    private var started: Bool = false
    private var baseElapsed: Int64 = 0
    private var baseTime: Int64 = 0

    init(renderSynchronizer: AVSampleBufferRenderSynchronizer) {
        self.renderSynchronizer = renderSynchronizer
    }

    func start() {
        guard !started else { return }
        baseElapsed = renderSynchronizer.currentTime().microseconds
        started = true
        renderSynchronizer.setRate(playbackRate, time: .from(microseconds: baseTime))
    }

    func stop() {
        guard started else { return }
        started = false
    }

    func resetPosition(position: Int64) {
        baseTime = position
        renderSynchronizer.setRate(0, time: .from(microseconds: position))
        if started {
            baseElapsed = renderSynchronizer.currentTime().microseconds
        }
    }

    func getPosition() -> Int64  {
        var position = baseTime
        if started {
            position = renderSynchronizer.currentTime().microseconds
        }

        return position
    }

    func setPlaybackRate(new playbackRate: Float) {
        guard self.playbackRate != playbackRate else { return }
        self.playbackRate = playbackRate
        if started {
            renderSynchronizer.rate = playbackRate
        }
    }
}
