//
//  CMTime+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

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
        Int64(seconds * 1_000_000)
    }

    var nanoseconds: Int64 {
        Int64(seconds * 1_000_000_000)
    }
}
