//
//  CMClock+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia.CMSync

extension CMClock {
    var milliseconds: Int64 {
        time.milliseconds
    }

    var microseconds: Int64 {
        time.microseconds
    }

    var nanoseconds: Int64 {
        time.nanoseconds
    }
}
