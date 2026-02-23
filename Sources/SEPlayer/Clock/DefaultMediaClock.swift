//
//  DefaultMediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import AVFoundation

final class DefaultMediaClock: MediaClock {
    private let standaloneClock: StandaloneClock
    private let rendererTimebase: CMTimebase

    private var rendererClock: MediaClock?
    private var renderClockSource: SERenderer?

    private var playbackParameters: PlaybackParameters = .default
    private var isUsingStandaloneClock: Bool = false
    private var standaloneClockIsStarted: Bool = false

    init(clock: SEClock) throws {
        standaloneClock = try StandaloneClock(clock: clock)
        rendererTimebase = try CMTimebase(sourceTimebase: standaloneClock.timebase)
    }

    func getTimebase() -> CMTimebase? {
        rendererTimebase
    }

    func start() {
        try! rendererTimebase.setRate(Double(playbackParameters.playbackRate))
        standaloneClockIsStarted = true
        standaloneClock.start()
    }

    func stop() {
        try! rendererTimebase.setRate(.zero)
        standaloneClockIsStarted = false
        standaloneClock.stop()
    }

    func resetPosition(positionUs: Int64) {
        try! rendererTimebase.setTime(.from(microseconds: positionUs))
        standaloneClock.resetPosition(positionUs: positionUs)
    }

    func onRendererEnabled(renderer: SERenderer) {
        let rendererMediaClock = renderer.getMediaClock()
        if let rendererMediaClock, rendererMediaClock !== rendererClock {
            rendererClock = rendererMediaClock
            renderClockSource = renderer
            rendererMediaClock.setPlaybackParameters(new: standaloneClock.getPlaybackParameters())
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

    func syncAndGetPosition(isReadingAhead: Bool) -> Int64 {
        syncClock(isReadingAhead: isReadingAhead)
        return getPositionUs()
    }

    func getPositionUs() -> Int64  {
        return rendererClock?.getPositionUs() ?? standaloneClock.getPositionUs()
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        self.playbackParameters = playbackParameters
        rendererClock?.setPlaybackParameters(new: playbackParameters)
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
            return
        }

        guard let rendererClock else { return }
        let rendererClockPosition = rendererClock.getPositionUs()
        if isUsingStandaloneClock {
            if rendererClockPosition < standaloneClock.getPositionUs() {
                standaloneClock.stop()
                return
            }
            isUsingStandaloneClock = false
            if standaloneClockIsStarted {
                standaloneClock.start()
            }
        }

        standaloneClock.resetPosition(positionUs: rendererClockPosition)
        try! rendererTimebase.setTime(.from(microseconds: rendererClockPosition))
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
