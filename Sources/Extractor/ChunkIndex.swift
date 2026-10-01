//
//  ChunkIndex.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//

import CoreMedia

struct ChunkIndex {
    public let count: Int

    public let sizes: [Int]
    public let offsets: [Int]
    public let durations: [CMTime]
    public let times: [CMTime]
    private let duration: CMTime

    init(
        sizes: [Int],
        offsets: [Int],
        durations: [CMTime],
        times: [CMTime]
    ) {
        self.sizes = sizes
        self.offsets = offsets
        self.durations = durations
        self.times = times

        self.count = sizes.count
        duration = if count > 0 {
            durations[count - 1] + times[count - 1]
        } else {
            .zero
        }
    }

    /// The last chunk starting at or before `time`, or the first chunk if `time` is earlier.
    func index(for time: CMTime) -> Int {
        var low = 0
        var high = count - 1
        var result = 0

        while low <= high {
            let middle = (low + high) / 2
            if times[middle] <= time {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        return result
    }
}

extension ChunkIndex: SeekMap {
    func isSeekable() -> Bool { true }

    func getDuration() -> CMTime { duration }

    func getSeekPoints(for time: CMTime) -> SeekPoints {
        guard count > 0 else { return SeekPoints(first: .start) }
        let chunkIndex = index(for: time)
        let seekPoint = SeekPoints.SeekPoint(
            time: times[chunkIndex],
            position: offsets[chunkIndex]
        )

        if seekPoint.time >= time || chunkIndex == count - 1 {
            return SeekPoints(first: seekPoint)
        } else {
            let nextSeekPoint = SeekPoints.SeekPoint(
                time: times[chunkIndex + 1],
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
            + ", timeUs=\(times)"
            + ", durationsUs=\(duration)"
            + ")";
    }
}
