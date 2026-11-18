//
//  TimebaseTimeObserver.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.07.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Calls a block on a queue as the time of a timebase moves; subclasses decide at which times.
///
/// A timer on the timebase fires at the next time to report. A timebase timer never fires for a time already
/// behind, so it is set again whenever the time jumps or the rate changes. The rate is the effective one, as the
/// timebase usually runs at rate 1 on a source that starts and stops.
///
/// Apart from ``invalidate()``, everything runs on the queue of the block.
class TimebaseTimeObserver {
    let timebase: CMTimebase
    let queue: DispatchQueue

    /// The effective rate when the last change was handled; zero before the first.
    private(set) var rate: Float64 = 0
    /// The effective rate before the last change.
    private(set) var previousRate: Float64 = 0

    /// The time to report: never below zero.
    var currentTime: CMTime {
        let time = timebase.time
        guard time.isNumeric, time.epoch == 0 else { return .zero }
        return max(time, .zero)
    }

    // Activated as soon as it's made: the initializer can throw, and releasing a source that was never activated
    // traps. Strict, so it fires on time rather than when the system finds it convenient.
    private let timer: DispatchSourceTimer
    private var notificationObservers: [NSObjectProtocol] = []
    private let lock = UnfairLock()
    private var isInvalidated = false // guarded by lock

    init(timebase: CMTimebase, queue: DispatchQueue) {
        self.timebase = timebase
        self.queue = queue
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.activate()
    }

    deinit {
        invalidate()
    }

    /// Starts following the timebase. Called once by the subclass, at the end of its initializer.
    final func startObserving() throws(TimebaseError) {
        timer.setEventHandler { [weak self] in
            guard let self, !invalidated else { return }
            timerDidFire()
        }
        try timebase.addTimer(timer)

        notificationObservers = [
            observe(CMTimebase.timeJumped) { $0.timeDidJump() },
            observe(CMTimebase.effectiveRateChanged) { $0.handleRateChange() },
        ]
        // Added while playing: the observer starts as it would when playback starts.
        if timebase.effectiveRate != rate {
            queue.async { [weak self] in self?.handleRateChange() }
        }
    }

    /// Stops calling the block. Called on the queue of the block, the block is not called again once this returns.
    final func invalidate() {
        let wasInvalidated = lock.withLock {
            defer { isInvalidated = true }
            return isInvalidated
        }
        guard !wasInvalidated else { return }

        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        try? timebase.setTimerNextFireTime(timer, fireTime: .invalid)
        try? timebase.removeTimer(timer)
        timer.cancel()
    }

    /// Fires the timer when the timebase reaches `time`; an invalid time never.
    final func setNextFireTime(_ time: CMTime) {
        try? timebase.setTimerNextFireTime(timer, fireTime: time)
    }

    /// Whether the block may still be called.
    final var invalidated: Bool {
        lock.withLock { isInvalidated }
    }

    // MARK: - Subclasses

    /// The timer reached the time set with ``setNextFireTime(_:)``.
    func timerDidFire() {}
    /// The effective rate changed: ``rate`` and ``previousRate`` tell from what to what.
    func rateDidChange() {}
    /// The time of the timebase jumped.
    func timeDidJump() {}

    // MARK: - Private

    private func observe(_ name: Notification.Name, handler: @escaping (TimebaseTimeObserver) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: timebase, queue: nil) { [weak self, queue] _ in
            queue.async { [weak self] in
                guard let self, !invalidated else { return }
                handler(self)
            }
        }
    }

    private func handleRateChange() {
        guard !invalidated else { return }
        let newRate = timebase.effectiveRate
        guard newRate != rate else { return }
        previousRate = rate
        rate = newRate
        rateDidChange()
    }
}

extension TimebaseTimeObserver: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func == (lhs: TimebaseTimeObserver, rhs: TimebaseTimeObserver) -> Bool {
        lhs === rhs
    }
}
