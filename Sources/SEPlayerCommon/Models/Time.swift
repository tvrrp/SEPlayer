//
//  Time.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

public extension Double {
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

public extension Int64 {
    static let microsecondsPerSecond: Int64 = 1_000_000
    static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static let endOfSource: Int64 = .min
    static let timeUnset: Int64 = .min + 1
}

public enum Time {
    public static func usToMs(timeUs: Int64) -> Int64 {
        (timeUs == .timeUnset || timeUs == .endOfSource) ? timeUs : timeUs / 1000
    }

    public static func msToUs(timeMs: Int64) -> Int64 {
        (timeMs == .timeUnset || timeMs == .endOfSource) ? timeMs : timeMs * 1000
    }
}
