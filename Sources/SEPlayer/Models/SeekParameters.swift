//
//  SeekParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

public struct SeekParameters: Hashable {
    public let toleranceBeforeUs: Int64
    public let toleranceAfterUs: Int64

    public init(toleranceBeforeUs: Int64, toleranceAfterUs: Int64) {
        assert(toleranceBeforeUs >= 0 && toleranceAfterUs >= 0)
        self.toleranceBeforeUs = toleranceBeforeUs
        self.toleranceAfterUs = toleranceAfterUs
    }
}

extension SeekParameters {
    public func resolveSyncPosition(positionUs: Int64, firstSyncUs: Int64, secondSyncUs: Int64) -> Int64 {
        guard toleranceBeforeUs != 0, toleranceAfterUs != 0 else {
            return positionUs
        }

        let minPositionUs = subtractWithOverflow(x: positionUs, y: Int64(toleranceBeforeUs), overflowResult: .min)
        let maxPositionUs = addWithOverflow(x: positionUs, y: Int64(toleranceAfterUs), overflowResult: .max)

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

private extension SeekParameters {
    func subtractWithOverflow(x: Int64, y: Int64, overflowResult: Int64) -> Int64 {
        let (value, result) = x.subtractingReportingOverflow(y)
        return result ? overflowResult : value
    }

    func addWithOverflow(x: Int64, y: Int64, overflowResult: Int64) -> Int64 {
        let (value, result) = x.addingReportingOverflow(y)
        return result ? overflowResult : value
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .zero)
    public static let closestSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .max)
    public static let previousSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .zero)
    public static let nextSync = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .max)
    public static let `default` = closestSync
}
