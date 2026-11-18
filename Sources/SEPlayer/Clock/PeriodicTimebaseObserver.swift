//
//  PeriodicTimebaseObserver.swift
//  SEPlayer
//
//  Created by tvrrp on 22.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Reports the time of a timebase at every multiple of an interval the time passes while it moves, and once more
/// whenever it starts, stops, or jumps.
///
/// The times reported on the interval are those of the timeline, not of the moment the observer was added: with an
/// interval of half a second, at 0.5, 1, 1.5, and so on, whatever time playback started at.
final class PeriodicTimebaseObserver: TimebaseTimeObserver {
    /// The shortest time between two reports on the interval, in host time: at high rates a short interval would
    /// otherwise come around faster than the block can run.
    private static let minimumHostInterval: Float64 = 0.005

    private let requestedInterval: CMTime
    private let block: (CMTime) -> Void
    /// The time reported last, so a jump to where the time already is isn't reported again.
    private var lastReportedTime: CMTime = .invalid

    /// - Parameter interval: A positive time.
    init(timebase: CMTimebase, interval: CMTime, queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws(TimebaseError) {
        precondition(interval.isNumeric && interval > .zero, "The interval of a periodic time observer must be a positive time")
        requestedInterval = interval
        self.block = block
        super.init(timebase: timebase, queue: queue)
        try startObserving()
    }

    override func timerDidFire() {
        report(currentTime)
        scheduleNextFire()
    }

    override func rateDidChange() {
        if rate == 0 {
            // Stopped: where it stopped.
            report(currentTime)
        } else if previousRate == 0 {
            // Started: where it starts, then on the interval.
            report(currentTime)
            scheduleNextFire()
        } else {
            // Another speed: the interval may have to grow.
            scheduleNextFire()
        }
    }

    override func timeDidJump() {
        let time = currentTime
        guard time != lastReportedTime else { return }
        report(time)
        if rate != 0 {
            scheduleNextFire()
        }
    }

    private func report(_ time: CMTime) {
        guard !invalidated else { return }
        lastReportedTime = time
        block(time)
    }

    /// Sets the timer to the first multiple of the interval past the current time, in the direction of playback. A
    /// multiple at the current time is behind: it was just reported.
    private func scheduleNextFire() {
        guard rate != 0 else { return }
        let interval = currentInterval
        let isForward = rate > 0
        let now = currentTime.convertScale(
            interval.timescale,
            method: isForward ? .roundTowardNegativeInfinity : .roundTowardPositiveInfinity
        )
        guard now.isNumeric else { return }

        let multiple = isForward
            ? Self.flooredDivision(now.value, interval.value) + 1
            : Self.ceiledDivision(now.value, interval.value) - 1
        let (value, overflow) = multiple.multipliedReportingOverflow(by: interval.value)
        guard !overflow else { return }
        setNextFireTime(CMTime(value: value, timescale: interval.timescale))
    }

    /// The interval asked for, or longer at a rate that would bring it around faster than the minimum host interval.
    private var currentInterval: CMTime {
        let speed = abs(rate)
        guard speed > 0, requestedInterval.seconds / speed < Self.minimumHostInterval else {
            return requestedInterval
        }
        let interval = CMTime(seconds: speed * Self.minimumHostInterval, preferredTimescale: 1_000_000)
        return interval.value > 0 ? interval : requestedInterval
    }

    private static func flooredDivision(_ dividend: Int64, _ divisor: Int64) -> Int64 {
        let quotient = dividend / divisor
        return dividend % divisor != 0 && dividend < 0 ? quotient - 1 : quotient
    }

    private static func ceiledDivision(_ dividend: Int64, _ divisor: Int64) -> Int64 {
        let quotient = dividend / divisor
        return dividend % divisor != 0 && dividend > 0 ? quotient + 1 : quotient
    }
}
