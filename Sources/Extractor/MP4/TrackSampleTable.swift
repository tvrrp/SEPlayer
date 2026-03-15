//
//  TrackSampleTable.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

import SEPlayerCommon

public struct TrackSampleTable {
    public let track: Track
    public let sampleCount: Int
    public let offsets: [Int]
    public let sizes: [Int]
    public let maximumSize: Int
    public let timestampsUs: [Int64]
    public let flags: [SampleFlags]
    public let syncSampleIndices: [Int]
    public let durationUs: Int64
    public let hasOnlySyncSamples: Bool

    init(
        track: Track,
        offsets: [Int],
        sizes: [Int],
        maximumSize: Int,
        timestampsUs: [Int64],
        flags: [SampleFlags],
        syncSampleIndices: [Int],
        hasOnlySyncSamples: Bool,
        durationUs: Int64,
        sampleCount: Int
    ) throws {
        try checkArgument(sizes.count == timestampsUs.count)
        try checkArgument(offsets.count == timestampsUs.count)
        try checkArgument(flags.count == timestampsUs.count)

        self.track = track
        self.offsets = offsets
        self.sizes = sizes
        self.maximumSize = maximumSize
        self.timestampsUs = timestampsUs
        self.syncSampleIndices = syncSampleIndices
        self.hasOnlySyncSamples = hasOnlySyncSamples
        self.durationUs = durationUs
        self.sampleCount = sampleCount

        var flags = flags
        if !flags.isEmpty {
            flags[flags.count - 1].insert(.lastSample)
        }
        self.flags = flags
    }

    func earlierOrEqualSyncSample(for timeUs: Int64) -> Int? {
        if hasOnlySyncSamples {
            return Util.binarySearch(
                array: timestampsUs,
                value: timeUs,
                inclusive: true,
                stayInBounds: false
            )
        }

        var low = 0
        var high = syncSampleIndices.count - 1
        var index: Int?

        while low <= high {
            let mid = low + ((high - low) / 2)
            let currentTimestamp = timestampsUs[syncSampleIndices[mid]]

            if currentTimestamp <= timeUs {
                index = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard var index else { return nil }

        let targetTimestamp = timestampsUs[syncSampleIndices[index]]
        // Only scan backwards if the found sample is an EXACT match for the search time.
        if targetTimestamp == timeUs {
            while index > 0, timestampsUs[syncSampleIndices[index - 1]] == targetTimestamp {
                index -= 1
            }
        }

        return syncSampleIndices[index]
    }

    public func laterOrEqualSyncSample(for timeUs: Int64) -> Int? {
        if hasOnlySyncSamples {
            return Util.binarySearchCeil(
                array: timestampsUs,
                value: timeUs,
                inclusive: true,
                stayInBounds: false
            )
        }

        var low = 0
        var high = syncSampleIndices.count - 1
        var index: Int?

        while low <= high {
            let mid = low + ((high - low) / 2)
            let currentTimestamp = timestampsUs[syncSampleIndices[mid]]

            if currentTimestamp >= timeUs {
                index = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        guard var index else { return nil }

        let targetTimestamp = timestampsUs[syncSampleIndices[index]]
        // Only scan backwards if the found sample is an EXACT match for the search time.
        if targetTimestamp == timeUs {
            while index < syncSampleIndices.count - 1,
                  timestampsUs[syncSampleIndices[index + 1]] == targetTimestamp {
                index += 1
            }
        }

        return syncSampleIndices[index]
    }
}
