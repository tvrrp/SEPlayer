//
//  CurrentTimeInterpolator.swift
//  DemoApp
//
//  Created by Damir Yackupov on 28.07.2026.
//

import CoreMedia
import SEPlayer
import QuartzCore
import QuartzCore

@MainActor
final class MediaTimeInterpolator {

    private let player: SEPlayer

    private var anchorMedia: Double = 0        // seconds
    private var anchorHost: CFTimeInterval = 0 // CACurrentMediaTime domain
    private var rate: Double = 0               // 0 == frozen (paused / stalled / idle)
    private var periodicTimeObserver: AnyObject?

    init(player: SEPlayer) {
        self.player = player
        player.delegate.addDelegate(self)
        // TODO: subscribe to player events, call the methods below.
        periodicTimeObserver = try! player.addPeriodicTimeObserver(for: CMTime(value: 1, timescale: 1), queue: .main) { [weak self] time in
            self?.playbackTimeChanged(time)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timeJumped),
            name: CMTimebase.timeJumped,
            object: player.timebase
        )
    }

    deinit {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
    }

    // MARK: - Player events (placeholders)

    // MARK: - Read (per vsync)

    /// Pass CADisplayLink.targetTimestamp.
    func time(at host: CFTimeInterval) -> Double {
        guard rate != 0 else { return anchorMedia }
        return anchorMedia + (host - anchorHost) * rate
    }

    // MARK: -

    private func anchor(_ media: Double, host: CFTimeInterval, rate: Double) {
        anchorMedia = media
        anchorHost = host
        self.rate = rate
    }

    /// Don't snap on every tick — callback jitter alone would step the playhead
    /// backwards once a second. Continue from the predicted position and bend the
    /// rate slightly so the error is absorbed before the next tick.
    private func correct(to media: Double, host: CFTimeInterval) {
        let predicted = anchorMedia + (host - anchorHost) * rate
        let error = media - predicted

        guard abs(error) < 0.2 else {           // real discontinuity
            anchor(media, host: host, rate: rate)
            return
        }

        let bound = 0.05 * abs(rate)
        anchorMedia = predicted
        anchorHost = host
        self.rate = rate + min(max(error, -bound), bound)  // error / 1s window
    }

    /// 1 Hz tick from addPeriodicTimeObserver.
    private func playbackTimeChanged(_ time: CMTime) {
        guard time.isNumeric else { return }
        guard rate != 0 else { return }   // frozen: ignore
        correct(to: time.seconds, host: CACurrentMediaTime())
    }

    /// Playing at `rate`, currently at `time`.
    private func playbackStarted(at time: CMTime, rate: Double) {
        anchor(time.seconds, host: CACurrentMediaTime(), rate: rate)
    }

    /// Paused, stalled (waitingToPlayAtSpecifiedRate), item swapped, not ready.
    private func playbackStopped(at time: CMTime) {
        anchor(time.seconds, host: CACurrentMediaTime(), rate: 0)
    }

    @objc
    private func timeJumped(_ notification: Notification) {
        guard CMTimebaseGetTypeID() == CFGetTypeID(notification.object as CFTypeRef) else {
            return
        }

        let timebase = notification.object as! CMTimebase
        DispatchQueue.main.async { [self] in
            anchor(timebase.time.seconds, host: CACurrentMediaTime(), rate: rate)
        }
    }
}

extension MediaTimeInterpolator: SEPlayerDelegate {
    func player(_ player: any Player, didChangeIsPlaying isPlaying: Bool) {
        if isPlaying {
            playbackStarted(at: player.currentPosition, rate: Double(player.playbackParameters.playbackRate))
        } else {
            playbackStopped(at: player.currentPosition)
        }
    }

    func player(_ player: any Player, didChangePlaybackParameters playbackParameters: PlaybackParameters) {
        self.player(player, didChangeIsPlaying: player.isPlaying)
    }
}
