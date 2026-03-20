//
//  SeekMap.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol SeekMap: AnyObject {
    func isSeekable() -> Bool
    func getDuration() -> CMTime
    func getSeekPoints(for time: CMTime) -> SeekPoints
}

public final class Unseekable: SeekMap {
    private let duration: CMTime
    private let startSeekPoints: SeekPoints

    public init(duration: CMTime, startPosition: Int) {
        self.duration = duration
        self.startSeekPoints = SeekPoints(
            first: startPosition == 0 ? .start : .init(time: .zero, position: startPosition)
        )
    }

    public func isSeekable() -> Bool { return false }
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
