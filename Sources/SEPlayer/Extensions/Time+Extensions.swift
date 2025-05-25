//
//  Time+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.01.2025.
//

extension Double {
    var millisecondsPerSecond: Int64 {
        Int64(self * 1_000)
    }

    var microsecondsPerSecond: Int64 {
        Int64(self * 1_000_000)
    }

    var nanosecondsPerSecond: Int64 {
        Int64(self * 1_000_000_000)
    }
}

extension Int64 {
    static let microsecondsPerSecond: Int64 = 1_000_000
    static let nanosecondsPerSecond: Int64 = 1_000_000_000

    public static let endOfSource: Int64 = .min
    public static let timeUnset: Int64 = .min + 1
}

enum Time {
    static func usToMs(timeUs: Int64) -> Int64 {
        (timeUs == .timeUnset || timeUs == .endOfSource) ? timeUs : timeUs / 1000
    }

    static func msToUs(timeUs: Int64) -> Int64 {
        (timeUs == .timeUnset || timeUs == .endOfSource) ? timeUs : timeUs * 1000
    }
}
