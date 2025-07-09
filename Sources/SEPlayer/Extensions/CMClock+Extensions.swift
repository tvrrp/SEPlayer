//
//  CMClock+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia.CMSync

extension CMClock {
    var milliseconds: Int64 {
        time.seconds.millisecondsPerSecond
    }

    var microseconds: Int64 {
        time.seconds.microsecondsPerSecond
    }

    var nanoseconds: Int64 {
        time.seconds.nanosecondsPerSecond
    }
}
