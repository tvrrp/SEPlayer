//
//  StandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreMedia.CMSync

final class StandaloneClock: MediaClock {
    var timebase: TimebaseSource? { clock.timebase }
    private let clock: SEClock

    private var playbackParameters: PlaybackParameters
    private var started: Bool = false
    private var baseElapsedUs: Int64 = 0
    private var baseUs: Int64 = 0

    init(clock: SEClock) throws {
        self.clock = clock
        playbackParameters = .default
    }

    func start() {
        guard !started else { return }

        do {
            try clock.setRate(Double(playbackParameters.playbackRate))
            try clock.setTime(.from(microseconds: getPositionUs()))
        } catch {
            print(error)
        }

        baseElapsedUs = clock.microseconds
        started = true
    }

    func stop() {
        guard started else { return }
        resetPosition(positionUs: getPositionUs())
        started = false

        do {
            try clock.setRate(Double(playbackParameters.playbackRate))
        } catch {
            print(error)
        }
    }

    func resetPosition(positionUs: Int64) {
        baseUs = positionUs
        if started {
            baseElapsedUs = clock.microseconds

            do {
                try clock.setRate(Double(playbackParameters.playbackRate))
                try clock.setTime(.from(microseconds: positionUs))
            } catch {
                print(error)
            }
        }
    }

    func getPositionUs() -> Int64  {
        var positionUs = baseUs
        if started {
            let elapsedSinceBase = clock.microseconds - baseElapsedUs
            positionUs += playbackParameters.mediaTimeForPlaybackRate(elapsedSinceBase)
        }

        return positionUs
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        if started {
            resetPosition(positionUs: getPositionUs())
        }
        self.playbackParameters = playbackParameters
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }
}
