//
//  CMClock+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia

extension CMClock {
    var microseconds: Int64 {
        time.seconds.microsecondsPerSecond
    }

    var nanoseconds: Int64 {
        time.seconds.nanosecondsPerSecond
    }
}
