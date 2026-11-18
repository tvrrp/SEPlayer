//
//  CMClock+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia

public extension CMClock {
    /// `time` of this clock as a time of `clock`.
    func convertTime(_ time: CMTime, to clock: CMClock) -> CMTime {
        CMSyncConvertTime(time, from: self, to: clock)
    }

    /// `time` of this clock as a time of `timebase`.
    func convertTime(_ time: CMTime, to timebase: CMTimebase) -> CMTime {
        CMSyncConvertTime(time, from: self, to: timebase)
    }

    func rate(relativeTo clock: CMClock) -> Double {
        CMSyncGetRelativeRate(self, relativeTo: clock)
    }

    func rate(relativeTo timebase: CMTimebase) -> Double {
        CMSyncGetRelativeRate(self, relativeTo: timebase)
    }
}
