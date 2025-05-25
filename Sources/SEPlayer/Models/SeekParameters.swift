//
//  SeekParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

public struct SeekParameters: Hashable {
    public let toleranceBeforeUs: UInt64
    public let toleranceAfterUs: UInt64

    public init(toleranceBeforeUs: UInt64, toleranceAfterUs: UInt64) {
        self.toleranceBeforeUs = toleranceBeforeUs
        self.toleranceAfterUs = toleranceAfterUs
    }
}

extension SeekParameters {
    public func resolveSyncPosition(positionUs: Int64, firstSyncUs: Int64, secondSyncUs: Int64) -> Int64 {
        guard toleranceBeforeUs != 0, toleranceAfterUs != 0 else {
            return positionUs
        }

        let minPositionUs = positionUs &- Int64(toleranceBeforeUs)
        let maxPositionUs = positionUs &+ Int64(toleranceAfterUs)

        let firstSyncPositionValid = (minPositionUs...maxPositionUs).contains(firstSyncUs)
        let secondSyncPositionValid = (minPositionUs...maxPositionUs).contains(secondSyncUs)

        if firstSyncPositionValid, secondSyncPositionValid {
            if abs(firstSyncUs - positionUs) <= abs(secondSyncUs - positionUs) {
                return firstSyncUs
            } else {
                return secondSyncUs
            }
        } else if firstSyncPositionValid {
            return firstSyncUs
        } else if secondSyncPositionValid {
            return secondSyncUs
        } else {
            return maxPositionUs
        }
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .zero)
    public static let closestSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .max)
    public static let previousSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .zero)
    public static let nextSync = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .max)
    public static let `default` = closestSync
}
