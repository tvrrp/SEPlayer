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
    private var baselineTime: CMTime = .zero

    init(clock: SEClock) throws {
        self.clock = clock
        playbackParameters = .default
        timebase = try clock.makeTimebase()
    }

    func start() {
        guard !started else { return }

        do {
//            try timebase.setTime(baselineTime)
            try timebase.setRate(to: Double(playbackParameters.playbackRate))
        } catch {
            SELogger.error(.clock, "Starting the clock failed: \(error)")
        }

        started = true
    }

    func stop() {
        guard started else { return }
        resetPosition(position: getPosition())
        started = false

        do {
            try timebase.setRate(to: .zero)
        } catch {
            SELogger.error(.clock, "Stopping the clock failed: \(error)")
        }
    }

    func resetPosition(position: CMTime) {
        do {
            try timebase.setTime(to: position)
//            baselineTime = position
//            if timebase.rate != 0 { try timebase.setTime(position) }
        } catch {
            SELogger.error(.clock, "Setting the clock to \(position.seconds) failed: \(error)")
        }
    }

    func getPosition() -> CMTime  {
        timebase.time
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        if started {
            if self.playbackParameters != playbackParameters {
                try! timebase.setRate(to: Double(playbackParameters.playbackRate))
            }
        }
        self.playbackParameters = playbackParameters
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }
}
