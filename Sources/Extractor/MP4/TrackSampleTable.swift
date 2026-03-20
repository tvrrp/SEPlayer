//
//  TrackSampleTable.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

import CoreMedia
import SEPlayerCommon

public struct TrackSampleTable {
    public let track: Track
    public let sampleCount: Int
    public let offsets: [Int]
    public let sizes: [Int]
    public let maximumSize: Int

    // CMTime-based timing (native timescale preserved).
    public let pts: [CMTime]
    public let dts: [CMTime]
    public let durations: [CMTime]
    public let duration: CMTime

    // Backward-compatible microsecond timing (derived from CMTime).
//    public let timestampsUs: [Int64]
//    public let durationUs: Int64

    public let flags: [SampleFlags]
    public let syncSampleIndices: [Int]
    public let hasOnlySyncSamples: Bool

    init(
        track: Track,
        offsets: [Int],
        sizes: [Int],
        maximumSize: Int,
        pts: [CMTime],
        dts: [CMTime],
        durations: [CMTime],
        duration: CMTime,
        flags: [SampleFlags],
        syncSampleIndices: [Int],
        hasOnlySyncSamples: Bool,
        sampleCount: Int
    ) throws {
        try checkArgument(sizes.count == sampleCount)
        try checkArgument(offsets.count == sampleCount)
        try checkArgument(flags.count == sampleCount)
        try checkArgument(pts.count == sampleCount)
        try checkArgument(dts.count == sampleCount)
        try checkArgument(durations.count == sampleCount)

        self.track = track
        self.offsets = offsets
        self.sizes = sizes
        self.maximumSize = maximumSize
        self.pts = pts
        self.dts = dts
        self.durations = durations
        self.duration = duration
//        self.timestampsUs = pts.map { $0.microseconds }
//        self.durationUs = duration.microseconds
        self.syncSampleIndices = syncSampleIndices
        self.hasOnlySyncSamples = hasOnlySyncSamples
        self.sampleCount = sampleCount

        var flags = flags
        if !flags.isEmpty {
            flags[flags.count - 1].insert(.lastSample)
        }
        self.flags = flags
    }

    static func empty(track: Track) throws -> TrackSampleTable {
        try TrackSampleTable(
            track: track,
            offsets: [],
            sizes: [],
            maximumSize: 0,
            pts: [],
            dts: [],
            durations: [],
            duration: .zero,
            flags: [],
            syncSampleIndices: [],
            hasOnlySyncSamples: false,
            sampleCount: 0
        )
    }

    // MARK: - Sync sample lookup

    func earlierOrEqualSyncSample(for time: CMTime) -> Int? {
        if hasOnlySyncSamples {
            return Util.binarySearch(
                array: pts,
                value: time,
                inclusive: true,
                stayInBounds: false
            )
        }

        var low = 0
        var high = syncSampleIndices.count - 1
        var index: Int?

        while low <= high {
            let mid = low + ((high - low) / 2)
            let currentTimestamp = pts[syncSampleIndices[mid]]

            if currentTimestamp <= time {
                index = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard var index else { return nil }

        let targetTimestamp = pts[syncSampleIndices[index]]
        // Only scan backwards if the found sample is an EXACT match for the search time.
        if targetTimestamp == time {
            while index > 0, pts[syncSampleIndices[index - 1]] == targetTimestamp {
                index -= 1
            }
        }

        return syncSampleIndices[index]
    }

    func laterOrEqualSyncSample(for time: CMTime) -> Int? {
        if hasOnlySyncSamples {
            return Util.binarySearchCeil(
                array: pts,
                value: time,
                inclusive: true,
                stayInBounds: false
            )
        }

        var low = 0
        var high = syncSampleIndices.count - 1
        var index: Int?

        while low <= high {
            let mid = low + ((high - low) / 2)
            let currentTimestamp = pts[syncSampleIndices[mid]]

            if currentTimestamp >= time {
                index = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        guard var index else { return nil }

        let targetTimestamp = pts[syncSampleIndices[index]]
        // Only scan backwards if the found sample is an EXACT match for the search time.
        if targetTimestamp == time {
            while index < syncSampleIndices.count - 1,
                  pts[syncSampleIndices[index + 1]] == targetTimestamp {
                index += 1
            }
        }

        return syncSampleIndices[index]
    }

//    func earlierOrEqualSyncSample(for timeUs: Int64) -> Int? {
//        if hasOnlySyncSamples {
//            return Util.binarySearch(
//                array: timestampsUs,
//                value: timeUs,
//                inclusive: true,
//                stayInBounds: false
//            )
//        }
//
//        var low = 0
//        var high = syncSampleIndices.count - 1
//        var index: Int?
//
//        while low <= high {
//            let mid = low + ((high - low) / 2)
//            let currentTimestamp = timestampsUs[syncSampleIndices[mid]]
//
//            if currentTimestamp <= timeUs {
//                index = mid
//                low = mid + 1
//            } else {
//                high = mid - 1
//            }
//        }
//
//        guard var index else { return nil }
//
//        let targetTimestamp = timestampsUs[syncSampleIndices[index]]
//        // Only scan backwards if the found sample is an EXACT match for the search time.
//        if targetTimestamp == timeUs {
//            while index > 0, timestampsUs[syncSampleIndices[index - 1]] == targetTimestamp {
//                index -= 1
//            }
//        }
//
//        return syncSampleIndices[index]
//    }
//
//    public func laterOrEqualSyncSample(for timeUs: Int64) -> Int? {
//        if hasOnlySyncSamples {
//            return Util.binarySearchCeil(
//                array: timestampsUs,
//                value: timeUs,
//                inclusive: true,
//                stayInBounds: false
//            )
//        }
//
//        var low = 0
//        var high = syncSampleIndices.count - 1
//        var index: Int?
//
//        while low <= high {
//            let mid = low + ((high - low) / 2)
//            let currentTimestamp = timestampsUs[syncSampleIndices[mid]]
//
//            if currentTimestamp >= timeUs {
//                index = mid
//                high = mid - 1
//            } else {
//                low = mid + 1
//            }
//        }
//
//        guard var index else { return nil }
//
//        let targetTimestamp = timestampsUs[syncSampleIndices[index]]
//        // Only scan backwards if the found sample is an EXACT match for the search time.
//        if targetTimestamp == timeUs {
//            while index < syncSampleIndices.count - 1,
//                  timestampsUs[syncSampleIndices[index + 1]] == targetTimestamp {
//                index += 1
//            }
//        }
//
//        return syncSampleIndices[index]
//    }
}
