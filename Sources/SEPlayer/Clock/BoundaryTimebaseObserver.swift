//
//  BoundaryTimebaseObserver.swift
//  SEPlayer
//
//  Created by tvrrp on 22.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Reports each of a set of times as the time of a timebase moves through it.
///
/// Only times that playback passes are reported: not a time jumped over, nor the time playback starts from.
/// Playing backwards, the times are passed in reverse.
final class BoundaryTimebaseObserver: TimebaseTimeObserver {
    /// In increasing order.
    private let times: [CMTime]
    private let block: (CMTime) -> Void
    /// The time the timer is set to.
    private var nextTime: CMTime = .invalid

    /// - Parameter times: At least one numeric time.
    init(timebase: CMTimebase, times: [CMTime], queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws(TimebaseError) {
        let times = times.filter(\.isNumeric).sorted()
        precondition(!times.isEmpty, "A boundary time observer needs a time to observe")
        self.times = times
        self.block = block
        super.init(timebase: timebase, queue: queue)
        try startObserving()
    }

    override func timerDidFire() {
        if nextTime.isValid, !invalidated {
            block(nextTime)
        }
        scheduleNextFire()
    }

    override func rateDidChange() {
        // Started, or turned around: the next time is another one. A change of speed alone leaves it.
        guard rate != 0, previousRate == 0 || (rate > 0) != (previousRate > 0) else {
            return
        }
        scheduleNextFire()
    }

    override func timeDidJump() {
        scheduleNextFire()
    }

    /// Sets the timer to the first time past the current time, in the direction of playback. A time at the current
    /// time is behind: it was reported already, or playback starts from it. While stopped the timer stays: it can't
    /// fire, and starting sets it again.
    private func scheduleNextFire() {
        guard rate != 0 else { return }
        let now = currentTime
        nextTime = if rate > 0 {
            times.first { $0 > now } ?? .invalid
        } else {
            times.last { $0 < now } ?? .invalid
        }
        setNextFireTime(nextTime)
    }
}
