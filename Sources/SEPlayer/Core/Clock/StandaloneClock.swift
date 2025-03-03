//
//  StandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreMedia

final class StandaloneClock: MediaClock {
    private let clock: CMClock

    private var playbackRate: Float = 1.0
    private var started: Bool = false
    private var baseElapsed: Int64 = 0
    private var baseTime: Int64 = 0

    init(clock: CMClock) {
        self.clock = clock
    }

    func start() {
        guard !started else { return }
        baseElapsed = clock.microseconds
        started = true
    }

    func stop() {
        guard started else { return }
        resetPosition(position: getPosition())
        started = false
    }

    func resetPosition(position: Int64) {
        baseTime = position
        if started {
            baseElapsed = clock.microseconds
        }
    }

    func getPosition() -> Int64  {
        var position = baseTime
        if started {
            let elapsedSinceBase = clock.microseconds - baseElapsed
            position += Int64(Double(elapsedSinceBase) * Double(playbackRate))
        }

        return position
    }

    func setPlaybackRate(new playbackRate: Float) {
        guard self.playbackRate != playbackRate else { return }
        self.playbackRate = playbackRate
    }
}
