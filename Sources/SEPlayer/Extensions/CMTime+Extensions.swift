//
//  CMTime+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime

@available(iOS, obsoleted: 16)
extension CMTime: @retroactive Hashable {
    public var hashValue: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
        hasher.combine(timescale)
        hasher.combine(epoch)
        hasher.combine(flags.rawValue)
    }
}

extension CMTime {
    var microseconds: Int64 {
        seconds.microsecondsPerSecond
    }

    var nanoseconds: Int64 {
        seconds.nanosecondsPerSecond
    }

    static func from(microseconds: Int64) -> CMTime {
        CMTime(value: microseconds, timescale: 1_000_000)
    }

    static func from(nanoseconds: Int64) -> CMTime {
        CMTime(value: nanoseconds, timescale: 1_000_000_000)
    }
}
