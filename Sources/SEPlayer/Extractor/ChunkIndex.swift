//
//  ChunkIndex.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//

final class ChunkIndex {
    public let count: Int

    public let sizes: [Int]
    public let offsets: [Int]
    public let durationsUs: [Int64]
    public let timesUs: [Int64]
    private let durationUs: Int64

    init(sizes: [Int], offsets: [Int], durationsUs: [Int64], timesUs: [Int64]) {
        self.sizes = sizes
        self.offsets = offsets
        self.durationsUs = durationsUs
        self.timesUs = timesUs

        self.count = sizes.count
        durationUs = if count > 0 {
            durationsUs[count - 1] + timesUs[count - 1]
        } else {
            .zero
        }
    }

    func index(for timeUs: Int64) -> Int {
        timesUs.firstIndex(of: timeUs) ?? .zero
    }
}

extension ChunkIndex: SeekMap {
    func isSeekable() -> Bool { true }

    func getDurationUs() -> Int64 { durationUs }

    func getSeekPoints(for timeUs: Int64) -> SeekPoints {
        let chunkIndex = index(for: timeUs)
        let seekPoint = SeekPoints.SeekPoint(
            timeUs: timesUs[chunkIndex],
            position: offsets[chunkIndex]
        )

        if seekPoint.timeUs >= timeUs || chunkIndex == count - 1 {
            return SeekPoints(first: seekPoint)
        } else {
            let nextSeekPoint = SeekPoints.SeekPoint(
                timeUs: timesUs[chunkIndex + 1],
                position: offsets[chunkIndex + 1]
            )

            return SeekPoints(first: seekPoint, second: nextSeekPoint)
        }
    }
}

extension ChunkIndex: CustomStringConvertible {
    var description: String {
        "ChunkIndex("
            + "count=\(count)"
            + ", sizes=\(sizes)"
            + ", offsets=\(offsets)"
            + ", timeUs=\(timesUs)"
            + ", durationsUs=\(durationUs)"
            + ")";
    }
}
