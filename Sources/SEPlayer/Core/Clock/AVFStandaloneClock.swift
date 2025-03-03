//
//  AVFStandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import AVFoundation

final class AVFStandaloneClock: MediaClock {
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
        resetPosition(position: getPosition())
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
        return started ? renderSynchronizer.currentTime().microseconds : baseTime
    }

    func setPlaybackRate(new playbackRate: Float) {
        guard self.playbackRate != playbackRate else { return }
        self.playbackRate = playbackRate
        if started {
            renderSynchronizer.rate = playbackRate
        }
    }
}
