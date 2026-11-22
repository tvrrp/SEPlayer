//
//  SeekParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.SeekParameters
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public struct SeekParameters: Hashable, Sendable {
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
    /// Whether the seek may land elsewhere than the position asked for.
    public var allowsTolerance: Bool {
        toleranceBefore > .zero || toleranceAfter > .zero
    }
}

extension SeekParameters {
    public static let exact = SeekParameters(toleranceBefore: .zero, toleranceAfter: .zero)
    public static let closestSync = SeekParameters(toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    public static let previousSync = SeekParameters(toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    public static let nextSync = SeekParameters(toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    public static let `default` = exact
}
