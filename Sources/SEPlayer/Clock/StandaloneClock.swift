//
//  StandaloneClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.01.2025.
//

import CoreMedia.CMSync
import SEPlayerCommon

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
        resetPosition(position: getPosition())
        started = false

        do {
            try timebase.setRate(Double(playbackParameters.playbackRate))
        } catch {
            print(error)
        }
    }

    func resetPosition(position: CMTime) {
        do {
            try timebase.setTime(position)
        } catch {
            print(error)
        }
    }

    func getPosition() -> CMTime  {
        timebase.time
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
