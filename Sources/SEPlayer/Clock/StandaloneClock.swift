//
//  StandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreMedia.CMSync

final class StandaloneClock: MediaClock {
    let timebase: CMTimebase
    private let clock: SEClock

    private var playbackParameters: PlaybackParameters
    private var started: Bool = false
    private var baseElapsedUs: Int64 = 0
    private var baseUs: Int64 = 0

    init(clock: SEClock) throws {
        self.clock = clock
        playbackParameters = .default
        timebase = try CMTimebase(sourceClock: clock.clock)
    }

    func start() {
        guard !started else { return }

        do {
            try timebase.setRate(Double(playbackParameters.playbackRate))
        } catch {
            print(error)
        }

        started = true
    }

    func stop() {
        guard started else { return }
        resetPosition(positionUs: getPositionUs())
        started = false

        do {
            try timebase.setRate(Double(playbackParameters.playbackRate))
        } catch {
            print(error)
        }
    }

    func resetPosition(positionUs: Int64) {
        do {
            try timebase.setTime(.from(microseconds: positionUs))
        } catch {
            print(error)
        }
    }

    func getPositionUs() -> Int64  {
        timebase.time.microseconds
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        if started {
            if self.playbackParameters != playbackParameters {
                try! timebase.setRate(Double(playbackParameters.playbackRate))
            }
        }
        self.playbackParameters = playbackParameters
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }
}
