//
//  DefaultMediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import CoreMedia

final class DefaultMediaClock: MediaClock {
    var playbackParameters: PlaybackParameters {
        get { getPlaybackParameters() }
        set {
            setPlaybackParameters(newValue)
        }
    }

    private let standaloneClock: StandaloneClock
    private var rendererClock: MediaClock?
    private var renderClockSource: BaseSERenderer?

    private var isUsingStandaloneClock: Bool = false
    private var standaloneClockIsStarted: Bool = false

    init(clock: CMClock) {
        standaloneClock = StandaloneClock(clock: clock)
    }

    func start() {
        standaloneClockIsStarted = true
        standaloneClock.start()
    }

    func stop() {
        standaloneClockIsStarted = false
        standaloneClock.stop()
    }

    func resetPosition(position: Int64) {
        standaloneClock.resetPosition(position: position)
    }

    func onRendererEnabled(renderer: BaseSERenderer) {
        let rendererMediaClock = renderer.getMediaClock()
        if let rendererMediaClock, rendererMediaClock !== rendererClock {
            rendererClock = rendererMediaClock
            renderClockSource = renderer
            rendererMediaClock.playbackParameters = standaloneClock.playbackParameters
        }
    }

    func onRendererDisabled(renderer: BaseSERenderer) {
        if renderer === rendererClock {
            rendererClock = nil
            renderClockSource = nil
        }
    }

    func syncAndGetPosition(isReadingAhead: Bool) -> Int64 {
        syncClock(isReadingAhead: isReadingAhead)
        return getPosition()
    }

    func getPosition() -> Int64  {
        return rendererClock?.getPosition() ?? standaloneClock.getPosition()
    }

    func setPlaybackRate(new playbackRate: Float) {
        standaloneClock.setPlaybackRate(new: playbackRate)
    }
    
    private func setPlaybackParameters(_ playbackParameters: PlaybackParameters) {
        rendererClock?.playbackParameters = playbackParameters
        standaloneClock.playbackParameters = playbackParameters
    }

    private func getPlaybackParameters() -> PlaybackParameters {
        rendererClock?.playbackParameters ?? standaloneClock.playbackParameters
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
        let rendererClockPosition = rendererClock.getPosition()
        if isUsingStandaloneClock {
            if rendererClockPosition < standaloneClock.getPosition() {
                standaloneClock.stop()
                return
            }
            isUsingStandaloneClock = false
            if standaloneClockIsStarted {
                standaloneClock.start()
            }
        }
        standaloneClock.resetPosition(position: rendererClockPosition)
        let playbackParameters = rendererClock.playbackParameters
        if playbackParameters != standaloneClock.playbackParameters {
            standaloneClock.playbackParameters = playbackParameters
        }
    }

    private func shouldUseStandaloneClock(isReadingAhead: Bool) -> Bool {
        guard let renderClockSource else { return true }

        return //|| renderClockSource.isEnded()
            (isReadingAhead && renderClockSource.isStarted == false)
            || (!renderClockSource.isReady())
//        && (isReadingAhead || renderClockSource )
    }
}
