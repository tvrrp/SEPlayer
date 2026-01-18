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
        precondition(toleranceBeforeUs >= 0 && toleranceAfterUs >= 0)
        self.toleranceBeforeUs = toleranceBeforeUs
        self.toleranceAfterUs = toleranceAfterUs
    }
}

extension SeekParameters {
    public func resolveSyncPosition(positionUs: Int64, firstSyncUs: Int64, secondSyncUs: Int64) -> Int64 {
        guard toleranceBeforeUs != 0 || toleranceAfterUs != 0 else {
            return positionUs
        }

        let minPositionUs = subtractWithOverflowDefault(positionUs, toleranceBeforeUs, defaultValue: Int64.min)
        let maxPositionUs = addWithOverflowDefault(positionUs, toleranceAfterUs, defaultValue: Int64.max)

        let firstValid = (minPositionUs <= firstSyncUs) && (firstSyncUs <= maxPositionUs)
        let secondValid = (minPositionUs <= secondSyncUs) && (secondSyncUs <= maxPositionUs)

        if firstValid && secondValid {
            if absOverflow(firstSyncUs - positionUs) <= absOverflow(secondSyncUs - positionUs) {
                return firstSyncUs
            } else {
                return secondSyncUs
            }
        } else if firstValid {
            return firstSyncUs
        } else if secondValid {
            return secondSyncUs
        } else {
            return minPositionUs
        }
    }
}

private extension SeekParameters {
    @inline(__always)
    func addWithOverflowDefault(_ x: Int64, _ y: Int64, defaultValue: Int64) -> Int64 {
        let (result, overflow) = x.addingReportingOverflow(y)
        return overflow ? defaultValue : result
    }

    @inline(__always)
    func subtractWithOverflowDefault(_ x: Int64, _ y: Int64, defaultValue: Int64) -> Int64 {
        let (result, overflow) = x.subtractingReportingOverflow(y)
        return overflow ? defaultValue : result
    }

    @inline(__always)
    func absOverflow(_ x: Int64) -> Int64 {
        if x == Int64.min { return Int64.min }
        return Swift.abs(x)
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .zero)
    public static let closestSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .max)
    public static let previousSync = SeekParameters(toleranceBeforeUs: .max, toleranceAfterUs: .zero)
    public static let nextSync = SeekParameters(toleranceBeforeUs: .zero, toleranceAfterUs: .max)
    public static let `default` = exact
}
