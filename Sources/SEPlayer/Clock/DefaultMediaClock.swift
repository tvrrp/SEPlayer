//
//  DefaultMediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.DefaultMediaClock
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import AVFoundation
import SEPlayerCommon

final class DefaultMediaClock: MediaClock {
    /// Runs the player's synchronizer when there is one, so the video stays in it with audio or without.
    private let standaloneClock: any StandaloneMediaClock
    /// The synchronizer the standalone clock runs.
    private let renderSynchronizer: (any PlaybackSynchronizer)?
    private var rendererTimebase: CMTimebase

    private var rendererClock: MediaClock?
    private var renderClockSource: SERenderer?

    private var playbackParameters: PlaybackParameters = .default
    private var isUsingStandaloneClock: Bool = true
    private var standaloneClockIsStarted: Bool = false
    /// What `rendererTimebase` runs on: the standalone clock, or the timebase of the renderer
    /// whose clock is in use. Video layers follow `rendererTimebase`, so it must always show the
    /// time of the clock the position comes from.
    private var timebaseSource: CMTimebase

    /// Called once the renderer clock reaches the standalone clock while `syncClock` waits for it
    /// to take over. The owner should sync again; nothing else would wake it.
    var onRendererClockCaughtUp: (() -> Void)?
    /// Called when ``getRendererTimeSource()`` changes: the owner hands the new source to the renderers.
    var onRendererTimeSourceChanged: ((RendererTimeSource) -> Void)?
    private var reportedTimeSource: RendererTimeSource?
    // Activated as soon as it's made: the initializer can throw, and releasing a source that was never activated traps.
    private let catchUpTimer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource()
        timer.activate()
        return timer
    }()

    private var catchUpTimebase: CMTimebase?

    private var baselineTime: CMTime = .zero

    init(clock: SEClock, outboundTimebase: CMTimebase, renderSynchronizer: (any PlaybackSynchronizer)? = nil) throws {
        self.renderSynchronizer = renderSynchronizer
        if let renderSynchronizer {
            standaloneClock = SynchronizerClock(synchronizer: renderSynchronizer)
        } else {
            standaloneClock = try StandaloneClock(clock: clock)
        }
        rendererTimebase = try CMTimebase(sourceTimebase: standaloneClock.timebase)
        timebaseSource = standaloneClock.timebase
        try outboundTimebase.setSource(rendererTimebase)

        catchUpTimer.setEventHandler { [weak self] in
            self?.onRendererClockCaughtUp?()
        }
    }

    deinit {
        catchUpTimer.cancel()
    }

    func getTimebase() -> CMTimebase {
        rendererTimebase
    }

    /// What the renderers play to. While the standalone clock is in use, its synchronizer. While a renderer's
    /// clock is, that renderer's synchronizer if it has one, so the video starts and changes rate with the audio;
    /// otherwise ``getTimebase()``.
    func getRendererTimeSource() -> RendererTimeSource {
        let synchronizer = isUsingStandaloneClock ? renderSynchronizer : renderClockSource?.getRenderSynchronizer()
        return synchronizer.map { .synchronizer($0) } ?? .timebase(rendererTimebase)
    }

    func start() throws {
        // The source already runs at the playback speed, so this timebase only follows it.
        try rendererTimebase.setRate(to: 1)
        standaloneClockIsStarted = true
        standaloneClock.start()
    }

    func stop() throws {
        try rendererTimebase.setRate(to: .zero)
        standaloneClockIsStarted = false
        standaloneClock.stop()
    }

    func resetPosition(position: CMTime) throws {
        try rendererTimebase.setTime(to: position)
        standaloneClock.resetPosition(position: position)
    }

    /// Only records the renderer's clock. It takes over in `syncClock`, once the renderer plays:
    /// a renderer enabled ahead of time, for the next item, must not move the clock yet.
    func onRendererEnabled(renderer: SERenderer) throws {
        let rendererMediaClock = renderer.getMediaClock()
        if let rendererMediaClock, rendererMediaClock !== rendererClock {
            rendererClock = rendererMediaClock
            renderClockSource = renderer
            try rendererMediaClock.setPlaybackParameters(new: standaloneClock.getPlaybackParameters())
        }
    }

    func onRendererDisabled(renderer: SERenderer) {
        if renderer === renderClockSource {
            SELogger.debug(.clock, "media clock: renderer clock disabled (\(type(of: renderer))), standalone at \(standaloneClock.timebase.time.seconds) rate \(standaloneClock.timebase.rate)")
            rendererClock = nil
            renderClockSource = nil
            isUsingStandaloneClock = true
            setTimebaseSource(standaloneClock.timebase)
            wakeWhenRendererClockReaches(nil, on: nil)
            reportRendererTimeSourceIfChanged()
        }
    }

    func syncAndGetPosition(isReadingAhead: Bool) -> CMTime {
        syncClock(isReadingAhead: isReadingAhead)
        reportRendererTimeSourceIfChanged()
        return getPosition()
    }

    private func reportRendererTimeSourceIfChanged() {
        let source = getRendererTimeSource()
        guard !source.isIdentical(to: reportedTimeSource) else { return }
        SELogger.debug(.clock, "media clock: renderer time source -> \(source.synchronizer != nil ? "synchronizer" : "timebase")")
        reportedTimeSource = source
        onRendererTimeSourceChanged?(source)
    }

    func getPosition() -> CMTime {
        if isUsingStandaloneClock {
            return standaloneClock.getPosition()
        }
        return rendererClock?.getPosition() ?? standaloneClock.getPosition()
    }

//    func getPosition() -> CMTime {
//        return isUsingStandaloneClock ? standaloneClock.getPosition() : (rendererClock?.getPosition() ?? .invalid)
//    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) throws {
        self.playbackParameters = playbackParameters
        try rendererClock?.setPlaybackParameters(new: playbackParameters)
        standaloneClock.setPlaybackParameters(new: playbackParameters)
    }

    func getPlaybackParameters() -> PlaybackParameters {
        rendererClock?.getPlaybackParameters() ?? standaloneClock.getPlaybackParameters()
    }

    private func syncClock(isReadingAhead: Bool) {
        if shouldUseStandaloneClock(isReadingAhead: isReadingAhead) {
            isUsingStandaloneClock = true
            if standaloneClockIsStarted {
                standaloneClock.start()
            }
            setTimebaseSource(standaloneClock.timebase)
            wakeWhenRendererClockReaches(nil, on: nil)
            return
        }

        guard let rendererClock, let renderClockSource else { return }
        let rendererClockPosition = rendererClock.getPosition()

        if isUsingStandaloneClock {
            // Taking over must not move time backwards: wait for the renderer clock to catch up.
            if rendererClockPosition < standaloneClock.getPosition() {
                standaloneClock.stop()
                wakeWhenRendererClockReaches(standaloneClock.getPosition(), on: renderClockSource.getTimebase())
                return
            }

            isUsingStandaloneClock = false
            if standaloneClockIsStarted {
                standaloneClock.start()
            }
            wakeWhenRendererClockReaches(nil, on: nil)
        }

        if let rendererSourceTimebase = renderClockSource.getTimebase() {
            setTimebaseSource(rendererSourceTimebase)
        }

        // Keeps the standalone clock in step, so it can take over at any moment.
        standaloneClock.resetPosition(position: rendererClockPosition)

        let playbackParameters = rendererClock.getPlaybackParameters()
        if playbackParameters != standaloneClock.getPlaybackParameters() {
            standaloneClock.setPlaybackParameters(new: playbackParameters)
        }
    }

    /// Arms a one-shot timer on the renderer's timebase for `time`; `nil` disarms it.
    private func wakeWhenRendererClockReaches(_ time: CMTime?, on timebase: CMTimebase?) {
        if let catchUpTimebase, catchUpTimebase !== timebase || time == nil {
            try? catchUpTimebase.setTimerNextFireTime(catchUpTimer, fireTime: .invalid)
            try? catchUpTimebase.removeTimer(catchUpTimer)
            self.catchUpTimebase = nil
        }

        guard let time, let timebase else { return }
        if catchUpTimebase == nil {
            try? timebase.addTimer(catchUpTimer)
            catchUpTimebase = timebase
        }
        try? timebase.setTimerNextFireTime(catchUpTimer, fireTime: time)
    }

    /// Runs `rendererTimebase` on `source`, at the source's time.
    private func setTimebaseSource(_ source: CMTimebase) {
        guard source !== timebaseSource else { return }
        SELogger.debug(.clock, "media clock: renderer timebase source -> \(source === standaloneClock.timebase ? "standalone" : "renderer") at \(source.time.seconds) rate \(source.rate)")
        timebaseSource = source
        try? rendererTimebase.setSource(source)
        try? rendererTimebase.setTime(to: source.time)
    }

    private func shouldUseStandaloneClock(isReadingAhead: Bool) -> Bool {
        guard let renderClockSource else { return true }
        if renderClockSource.isRecoveringWhileTimelineAdvances { return false }

        // A synchronizer's timebase keeps going after its audio ends or runs short, until the renderer stops it, so
        // it stays the clock; leaving it would take the video out of the synchronizer at every item boundary. Only a
        // renderer enabled ahead for the next item, not yet started, can't drive the item still playing.
        if renderClockSource.getRenderSynchronizer() != nil {
            return isReadingAhead && renderClockSource.getState() != .started
        }

        return renderClockSource.isEnded()
            || (isReadingAhead && renderClockSource.getState() != .started)
            || (!renderClockSource.isReady() && (isReadingAhead || renderClockSource.didReadStreamToEnd()))
    }
}
