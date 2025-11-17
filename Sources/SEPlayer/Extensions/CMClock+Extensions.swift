//
//  CMClock+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import CoreMedia.CMSync

extension CMClock {
    public var milliseconds: Int64 {
        time.milliseconds
    }

    public var microseconds: Int64 {
        time.microseconds
    }

    public var nanoseconds: Int64 {
        time.nanoseconds
    }
}
