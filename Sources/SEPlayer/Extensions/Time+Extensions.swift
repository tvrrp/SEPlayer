//
//  Time+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.01.2025.
//

extension Double {
    var microsecondsPerSecond: Int64 {
        Int64(self * 1_000_000)
    }

    var nanosecondsPerSecond: Int64 {
        Int64(self * 1_000_000_000)
    }
}

extension Int64 {
    static var microsecondsPerSecond: Int64 = 1_000_000
    static var nanosecondsPerSecond: Int64 = 1_000_000_000

    static var endOfSource: Int64 = .min
    static var timeUnset: Int64 = .min + 1
}
