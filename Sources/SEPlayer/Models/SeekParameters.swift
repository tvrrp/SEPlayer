//
//  SeekParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

public struct SeekParameters: Hashable {
    public let toleranceBefore: UInt64
    public let toleranceAfter: UInt64

    public init(toleranceBefore: UInt64, toleranceAfter: UInt64) {
        self.toleranceBefore = toleranceBefore
        self.toleranceAfter = toleranceAfter
    }
}

extension SeekParameters {
    public func resolveSyncPosition(position: Int64, firstSync: Int64, secondSync: Int64) -> Int64 {
        guard toleranceBefore != 0, toleranceAfter != 0 else {
            return position
        }

        // TODO: calc
        return position
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBefore: .zero, toleranceAfter: .zero)
    public static let closestSync = SeekParameters(toleranceBefore: .max, toleranceAfter: .max)
    public static let previousSync = SeekParameters(toleranceBefore: .max, toleranceAfter: .zero)
    public static let nextSync = SeekParameters(toleranceBefore: .zero, toleranceAfter: .max)
    public static let `default` = closestSync
}
