//
//  SeekMap.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.SeekMap
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public protocol SeekMap {
    func isSeekable() -> Bool
    func getDuration() -> CMTime
    func getSeekPoints(for time: CMTime) -> SeekPoints
}

public struct Unseekable: SeekMap {
    private let duration: CMTime
    private let startSeekPoints: SeekPoints

    public init(duration: CMTime, startPosition: Int = 0) {
        self.duration = duration
        self.startSeekPoints = SeekPoints(
            first: startPosition == 0 ? .start : .init(time: .zero, position: startPosition)
        )
    }

    public func isSeekable() -> Bool { false }
    public func getDuration() -> CMTime { duration }
    public func getSeekPoints(for time: CMTime) -> SeekPoints { startSeekPoints }
}

public struct SeekPoints: Hashable, Sendable {
    public let first: SeekPoint
    public let second: SeekPoint

    public init(first: SeekPoint, second: SeekPoint? = nil) {
        self.first = first
        self.second = second ?? first
    }
}

public extension SeekPoints {
    struct SeekPoint: Hashable, Sendable {
        public let time: CMTime
        public let position: Int

        public init(time: CMTime, position: Int) {
            self.time = time
            self.position = position
        }

        public static let start = SeekPoint(time: .zero, position: 0)
    }
}
