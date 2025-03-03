//
//  DefaultMediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import CoreMedia

final class DefaultMediaClock {
    private let standaloneClock: StandaloneClock
    private var rendererClock: MediaClock?

    init(clock: CMClock) {
        standaloneClock = StandaloneClock(clock: clock)
    }

    func onRendererEnabled(renderer: BaseSERenderer) {
        rendererClock = rendererClock ?? renderer.getMediaClock()
    }

    func onRendererDisabled(renderer: BaseSERenderer) {
        if renderer === rendererClock {
            rendererClock = nil
        }
    }

    func syncAndGetPosition() {
        
    }

    func start() {
        standaloneClock.start()
    }

    func stop() {
        standaloneClock.stop()
    }

    func resetPosition(position: Int64) {
        standaloneClock.resetPosition(position: position)
    }

    func getPosition() -> Int64  {
        return rendererClock?.getPosition() ?? standaloneClock.getPosition()
    }

    func setPlaybackRate(new playbackRate: Float) {
        standaloneClock.setPlaybackRate(new: playbackRate)
    }

    private func syncClock() {
        
    }
}
