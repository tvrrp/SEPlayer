//
//  SeekParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

import CoreMedia

public struct SeekParameters: Hashable {
    public let toleranceBefore: CMTime
    public let toleranceAfter: CMTime

    public init(toleranceBefore: CMTime, toleranceAfter: CMTime) {
        precondition(toleranceBefore >= .zero && toleranceAfter >= .zero)
        self.toleranceBefore = toleranceBefore
        self.toleranceAfter = toleranceAfter
    }
}

extension SeekParameters {
    public func resolveSyncPosition(position: CMTime, firstSync: CMTime, secondSync: CMTime) -> CMTime {
        guard toleranceBefore != .zero || toleranceAfter != .zero else {
            return position
        }

        let minPosition = position - toleranceBefore
        let maxPosition = position + toleranceAfter

        let firstValid = (minPosition <= firstSync) && (firstSync <= maxPosition)
        let secondValid = (minPosition <= secondSync) && (secondSync <= maxPosition)

        if firstValid && secondValid {
            let firstDelta = CMTimeAbsoluteValue(firstSync - position)
            let secondDelta = CMTimeAbsoluteValue(secondSync - position)
            return firstDelta <= secondDelta ? firstSync : secondSync
        } else if firstValid {
            return firstSync
        } else if secondValid {
            return secondSync
        } else {
            return minPosition
        }
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBefore: .zero, toleranceAfter: .zero)
    public static let closestSync = SeekParameters(toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    public static let previousSync = SeekParameters(toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    public static let nextSync = SeekParameters(toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    public static let `default` = exact
}
