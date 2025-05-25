//
//  SeekMap.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol SeekMap {
    func isSeekable() -> Bool
    func getDurationUs() -> Int64
    func getSeekPoints(for timeUs: Int64) -> SeekPoints
}

public struct Unseekable: SeekMap {
    private let durationUs: Int64
    private let startSeekPoints: SeekPoints

    public init(durationUs: Int64, startPosition: Int) {
        self.durationUs = durationUs
        self.startSeekPoints = SeekPoints(
            first: startPosition == 0 ? .start : .init(timeUs: 0, position: startPosition)
        )
    }

    public func isSeekable() -> Bool { return false }
    public func getDurationUs() -> Int64 { durationUs }
    public func getSeekPoints(for timeUs: Int64) -> SeekPoints { startSeekPoints }
}

public struct SeekPoints: Hashable {
    let first: SeekPoint
    let second: SeekPoint

    public init(first: SeekPoint, second: SeekPoint? = nil) {
        self.first = first
        self.second = second ?? first
    }
}

public extension SeekPoints {
    struct SeekPoint: Hashable {
        let timeUs: Int64
        let position: Int

        public init(timeUs: Int64, position: Int) {
            self.timeUs = timeUs
            self.position = position
        }

        static let start = SeekPoint(timeUs: 0, position: 0)
    }
}
