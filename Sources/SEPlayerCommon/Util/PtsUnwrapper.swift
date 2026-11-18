//
//  PtsUnwrapper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.08.2026.
//

import CoreMedia
import Foundation

/// Unwraps 33-bit MPEG-2 TS timestamps into a monotonic tick space.
public struct PtsUnwrapper {
    private static let wrap: Int64 = 1 << 33

    private var last: Int64?

    public init() {}

    /// Assumes the timestamp is close to the previous one.
    public mutating func unwrap(_ raw33: Int64) -> Int64 {
        guard let last else {
            self.last = raw33
            return raw33
        }
        let closest = (last + Self.wrap / 2) / Self.wrap
        let below = raw33 + Self.wrap * (closest - 1)
        let above = raw33 + Self.wrap * closest
        let result = abs(below - last) < abs(above - last) ? below : above
        self.last = result
        return result
    }

    /// Assumes the timestamp is strictly greater than the previous one.
    public mutating func unwrapGreaterThanPrevious(_ raw33: Int64) -> Int64 {
        guard let last else {
            self.last = raw33
            return raw33
        }
        let wrapCount = last / Self.wrap
        let sameWrap = raw33 + Self.wrap * wrapCount
        let nextWrap = raw33 + Self.wrap * (wrapCount + 1)
        let result = sameWrap >= last ? sameWrap : nextWrap
        self.last = result
        return result
    }

    public mutating func reset() {
        last = nil
    }
}
