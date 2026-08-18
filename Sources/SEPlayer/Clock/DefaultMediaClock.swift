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
    private var isUsingStandaloneClock: Bool = false
    private var standaloneClockIsStarted: Bool = false

    private var baselineTime: CMTime = .zero
    private var timeObservers = Set<TimebaseTimeObserver>()

    init(clock: SEClock, outboundTimebase: CMTimebase) throws {
        standaloneClock = try StandaloneClock(clock: clock)
        rendererTimebase = try CMTimebase(sourceTimebase: standaloneClock.timebase)
        outboundTimebase.source = rendererTimebase
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
//        try! rendererTimebase.setTime(baselineTime)
        try! rendererTimebase.setRate(Double(playbackParameters.playbackRate))
        standaloneClockIsStarted = true
        standaloneClock.start()
    }

    func stop() {
        try! rendererTimebase.setRate(.zero)
//        resetPosition(position: rendererTimebase.time)
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

    func onRendererEnabled(renderer: SERenderer) throws {
        let rendererMediaClock = renderer.getMediaClock()
        if let rendererMediaClock, rendererMediaClock !== rendererClock {
            rendererClock = rendererMediaClock
            renderClockSource = renderer
            try rendererMediaClock.setPlaybackParameters(new: standaloneClock.getPlaybackParameters())
        }

        if let rendererSourceTimebase = renderer.getTimebase() {
            self.rendererTimebase.source = rendererSourceTimebase
        }
    }

    func onRendererDisabled(renderer: SERenderer) {
        if renderer === rendererClock {
            rendererClock = nil
            renderClockSource = nil

            rendererTimebase.source = standaloneClock.timebase
        }
    }

    func syncAndGetPosition(isReadingAhead: Bool) -> CMTime {
        syncClock(isReadingAhead: isReadingAhead)
        return getPosition()
    }

    func getPosition() -> CMTime {
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
            if let rendererClock {
                standaloneClock.resetPosition(position: rendererClock.getPosition())
            }

            isUsingStandaloneClock = true
            if standaloneClockIsStarted {
                standaloneClock.start()
            }
            return
        }

        guard let rendererClock else { return }
//        let rendererClockPosition = rendererClock.getPositionUs()
//        if isUsingStandaloneClock {
//            if rendererClockPosition < standaloneClock.getPositionUs() {
//                standaloneClock.stop()
//                return
//            }
//            isUsingStandaloneClock = false
//            if standaloneClockIsStarted {
//                standaloneClock.start()
//            }
//        }

//        standaloneClock.resetPosition(positionUs: rendererClockPosition)
//        try! rendererTimebase.setTime(.from(microseconds: rendererClockPosition))
        let playbackParameters = rendererClock.getPlaybackParameters()
        if playbackParameters != standaloneClock.getPlaybackParameters() {
            standaloneClock.setPlaybackParameters(new: playbackParameters)
        }
    }

    private func shouldUseStandaloneClock(isReadingAhead: Bool) -> Bool {
        guard let renderClockSource else { return true }

        return renderClockSource.isEnded()
            || (isReadingAhead && renderClockSource.getState() != .started)
            || !renderClockSource.isReady()
            && isReadingAhead || renderClockSource.didReadStreamToEnd()
    }
}
