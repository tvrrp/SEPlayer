//
//  SynchronizerClock.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.StandaloneMediaClock
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import AVFoundation
import SEPlayerCommon

/// The clock the player keeps when no renderer provides one.
protocol StandaloneMediaClock: AnyObject {
    /// The time of the clock, for timers and for the timebases that follow it.
    var timebase: CMTimebase { get }

    func start()
    func stop()
    func resetPosition(position: CMTime)
    func getPosition() -> CMTime
    func setPlaybackParameters(new playbackParameters: PlaybackParameters)
    func getPlaybackParameters() -> PlaybackParameters
}

extension StandaloneClock: StandaloneMediaClock {}

/// A clock that runs the synchronizer of the player.
///
/// The player starts, stops and moves the synchronizer whether or not anything plays in it, so the renderers that
/// join it keep the same clock across items, with audio or without. The synchronizer's own timebase is the time:
/// while it holds the rate for its renderers to get enough data, the clock holds too.
final class SynchronizerClock: StandaloneMediaClock {
    var timebase: CMTimebase { synchronizer.timebase }

    private let synchronizer: any PlaybackSynchronizer
    /// Whether the audio route buffers before it plays.
    private let isRouteBuffered: () -> Bool
    private var playbackParameters: PlaybackParameters = .default
    private var started = false

    init(synchronizer: any PlaybackSynchronizer, isRouteBuffered: @escaping () -> Bool = { AudioRoute.isAirPlay }) {
        self.synchronizer = synchronizer
        self.isRouteBuffered = isRouteBuffered
    }

    func start() {
        guard !started else { return }
        started = true
        // Buffered AirPlay starts a second or more after the rate is set, and loses the audio that comes late: there the
        // synchronizer waits until the renderers have enough. Elsewhere the player decides that, with less video than
        // the synchronizer waits for.
        let delaysStart = isRouteBuffered()
        if synchronizer.delaysRateChangeUntilHasSufficientMediaData != delaysStart {
            SELogger.debug(.clock, "synchronizer clock: \(delaysStart ? "waits" : "doesn't wait") for enough media data to start")
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = delaysStart
        }
        SELogger.debug(.clock, "synchronizer clock: start at \(synchronizer.currentTime().seconds) rate \(playbackParameters.playbackRate)")
        synchronizer.rate = playbackParameters.playbackRate
    }

    func stop() {
        guard started else { return }
        started = false
        SELogger.debug(.clock, "synchronizer clock: stop at \(synchronizer.currentTime().seconds)")
        synchronizer.rate = .zero
    }

    func resetPosition(position: CMTime) {
        synchronizer.setRate(started ? playbackParameters.playbackRate : .zero, time: position)
    }

    func getPosition() -> CMTime {
        synchronizer.currentTime()
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        if started, self.playbackParameters != playbackParameters {
            synchronizer.rate = playbackParameters.playbackRate
        }
        self.playbackParameters = playbackParameters
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }
}
