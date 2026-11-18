//
//  TimebaseTimer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// A timer that fires on a queue when the time of a timebase reaches a time.
///
/// Renderers set and cancel their timers for every sample they handle; the timer only asks the timebase to change
/// when the time is a different one. Use it on its queue only.
final class TimebaseTimer {
    private let source: DispatchSourceTimer
    private var timebase: CMTimebase?
    /// The time the timer is set to fire at, invalid for never; `nil` when unknown, as after it fired.
    private var fireTime: CMTime?

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.activate()
    }

    func setEventHandler(_ handler: @escaping () -> Void) {
        source.setEventHandler { [weak self] in
            // A time may have been set between firing and this handler, so the next time is always set.
            self?.fireTime = nil
            handler()
        }
    }

    deinit {
        source.cancel()
    }

    /// Moves the timer to `timebase`; the time it was set to stays with the old one.
    func setTimebase(_ timebase: CMTimebase?) throws(TimebaseError) {
        guard timebase !== self.timebase else { return }
        try? self.timebase?.removeTimer(source)
        self.timebase = timebase
        fireTime = nil
        try timebase?.addTimer(source)
    }

    /// Fires the timer when the timebase reaches `time`; an invalid time never.
    func setFireTime(_ time: CMTime) throws(TimebaseError) {
        guard let timebase else { return }
        // Invalid times are equal to each other.
        if let fireTime, fireTime == time { return }
        fireTime = nil
        try timebase.setTimerNextFireTime(source, fireTime: time)
        fireTime = time
    }

    /// Stops the timer from firing.
    func cancel() {
        try? setFireTime(.invalid)
    }
}
