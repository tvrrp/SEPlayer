//
//  CMClock+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia

extension CMClock {
    var microseconds: Int64 {
        Int64(time.seconds * 1_000_000)
    }

    var nanoseconds: Int64 {
        Int64(time.seconds * 1_000_000_000)
    }
}
