//
//  DefaultMediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import AVFoundation
import SEPlayerCommon

final class DefaultMediaClock: MediaClock {
    private let standaloneClock: StandaloneClock
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
    private let catchUpTimer = DispatchSource.makeTimerSource()
    private var catchUpTimebase: CMTimebase?

    private var baselineTime: CMTime = .zero
    private var timeObservers = Set<TimebaseTimeObserver>()

    init(clock: SEClock, outboundTimebase: CMTimebase) throws {
        standaloneClock = try StandaloneClock(clock: clock)
        rendererTimebase = try CMTimebase(sourceTimebase: standaloneClock.timebase)
        timebaseSource = standaloneClock.timebase
        outboundTimebase.source = rendererTimebase

        catchUpTimer.setEventHandler { [weak self] in
            self?.onRendererClockCaughtUp?()
        }
        catchUpTimer.activate()
    }

    deinit {
        catchUpTimer.cancel()
    }

    func addPeriodicTimeObserver(
        for interval: CMTime,
        queue: DispatchQueue,
        block: @escaping (CMTime) -> Void
    ) throws -> AnyObject {
        let observer = try TimebaseTimeObserver(
            queue: queue,
            timebase: rendererTimebase,
            sourceType: .periodic(interval),
            block: block
        )
        timeObservers.insert(observer)
        return observer
    }

    func addBoundaryTimeObserver(
        for times: [CMTime],
        queue: DispatchQueue,
        block: @escaping (CMTime) -> Void
    ) throws -> AnyObject {
        let observer = try TimebaseTimeObserver(
            queue: queue,
            timebase: rendererTimebase,
            sourceType: .boundary(times),
            block: block
        )
        timeObservers.insert(observer)
        return observer
    }

    func removeTimeObserver(_ observer: AnyObject) {
        guard let observer = observer as? TimebaseTimeObserver else {
            return
        }

        timeObservers.remove(observer)
    }

    func getTimebase() -> CMTimebase {
        rendererTimebase
    }

    func start() {
        // The source already runs at the playback speed, so this timebase only follows it.
        try! rendererTimebase.setRate(1)
        standaloneClockIsStarted = true
        standaloneClock.start()
    }

    func stop() {
        try! rendererTimebase.setRate(.zero)
        standaloneClockIsStarted = false
        standaloneClock.stop()
    }

    func resetPosition(position: CMTime) {
//        baselineTime = position
        try! rendererTimebase.setTime(position)
//        if rendererTimebase.rate != 0 {
//            try! rendererTimebase.setTime(baselineTime)
//        }
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
            rendererClock = nil
            renderClockSource = nil
            isUsingStandaloneClock = true
            setTimebaseSource(standaloneClock.timebase)
            wakeWhenRendererClockReaches(nil, on: nil)
        }
    }

    func syncAndGetPosition(isReadingAhead: Bool) -> CMTime {
        syncClock(isReadingAhead: isReadingAhead)
        return getPosition()
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

//    private func syncClock(isReadingAhead: Bool) {
//        if shouldUseStandaloneClock(isReadingAhead: isReadingAhead) {
//            isUsingStandaloneClock = true
//            if standaloneClockIsStarted {
//                standaloneClock.start()
//            }
//            return
//        }
//
//        guard let rendererClock else { return }
//        let rendererClockPosition = rendererClock.getPosition()
//
//        if isUsingStandaloneClock {
//            if rendererClockPosition < standaloneClock.getPosition() {
//                standaloneClock.stop()
//                return
//            }
//
//            isUsingStandaloneClock = false
//            if standaloneClockIsStarted {
//                standaloneClock.start()
//            }
//        }
//
//        standaloneClock.resetPosition(position: rendererClockPosition)
////        standaloneClock.resetPosition(position: rendererClock.getPosition())
////        let rendererClockPosition = rendererClock.getPositionUs()
////        if isUsingStandaloneClock {
////            if rendererClockPosition < standaloneClock.getPositionUs() {
////                standaloneClock.stop()
////                return
////            }
////            isUsingStandaloneClock = false
////            if standaloneClockIsStarted {
////                standaloneClock.start()
////            }
////        }
//
////        standaloneClock.resetPosition(positionUs: rendererClockPosition)
////        try! rendererTimebase.setTime(.from(microseconds: rendererClockPosition))
//        let playbackParameters = rendererClock.getPlaybackParameters()
//        if playbackParameters != standaloneClock.getPlaybackParameters() {
//            standaloneClock.setPlaybackParameters(new: playbackParameters)
//        }
//    }

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
        timebaseSource = source
        rendererTimebase.source = source
        try? rendererTimebase.setTime(source.time)
    }

    private func shouldUseStandaloneClock(isReadingAhead: Bool) -> Bool {
        guard let renderClockSource else { return true }

        return renderClockSource.isEnded()
            || (isReadingAhead && renderClockSource.getState() != .started)
            || (!renderClockSource.isReady() && (isReadingAhead || renderClockSource.didReadStreamToEnd()))
    }
}
