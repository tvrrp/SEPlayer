//
//  CMTimebase+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia
import Dispatch
import Foundation

public extension _CoreMediaInitializable where Self == CMTimebase {
    /// A timebase that runs on `sourceClock`, stopped at time zero.
    init(sourceClock: CMClock) throws(TimebaseError) {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: sourceClock, timebaseOut: &timebase)
        guard status == noErr, let timebase else {
            throw TimebaseError(status: status)
        }
        self = timebase
    }

    /// A timebase that runs on `sourceTimebase`, stopped at time zero.
    init(sourceTimebase: CMTimebase) throws(TimebaseError) {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault, sourceTimebase: sourceTimebase, timebaseOut: &timebase)
        guard status == noErr, let timebase else {
            throw TimebaseError(status: status)
        }
        self = timebase
    }
}

public extension CMTimebase {
    // MARK: - Source

    /// Runs the timebase on `clock`, keeping its time.
    func setSource(_ clock: CMClock) throws(TimebaseError) {
        let status = CMTimebaseSetSourceClock(self, clock)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    /// Runs the timebase on `timebase`, keeping its time.
    func setSource(_ timebase: CMTimebase) throws(TimebaseError) {
        let status = CMTimebaseSetSourceTimebase(self, timebase)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    // MARK: - Time and rate

    func setTime(to time: CMTime) throws(TimebaseError) {
        let status = CMTimebaseSetTime(self, time: time)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    func setRate(to rate: Double) throws(TimebaseError) {
        let status = CMTimebaseSetRate(self, rate: rate)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    // MARK: - Timers

    /// Fires `timer` at the times set with ``setTimerNextFireTime(_:fireTime:)``, following the timebase.
    func addTimer(_ timer: any DispatchSourceTimer) throws(TimebaseError) {
        let status = CMTimebaseAddTimerDispatchSource(self, timerSource: timer as! DispatchSource)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    func removeTimer(_ timer: any DispatchSourceTimer) throws(TimebaseError) {
        let status = CMTimebaseRemoveTimerDispatchSource(self, timerSource: timer as! DispatchSource)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    /// Fires `timer` when the timebase reaches `fireTime`; an invalid time never.
    func setTimerNextFireTime(_ timer: any DispatchSourceTimer, fireTime: CMTime) throws(TimebaseError) {
        let status = CMTimebaseSetTimerDispatchSourceNextFireTime(self, timerSource: timer as! DispatchSource, fireTime: fireTime, flags: 0)
        guard status == noErr else { throw TimebaseError(status: status) }
    }

    // MARK: - Relating to clocks and other timebases

    /// `time` of this timebase as a time of `clock`.
    func convertTime(_ time: CMTime, to clock: CMClock) -> CMTime {
        CMSyncConvertTime(time, from: self, to: clock)
    }

    /// `time` of this timebase as a time of `timebase`.
    func convertTime(_ time: CMTime, to timebase: CMTimebase) -> CMTime {
        CMSyncConvertTime(time, from: self, to: timebase)
    }
}
