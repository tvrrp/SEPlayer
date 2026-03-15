//
//  FixedSampleSizeRechunker.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

import SEPlayerCommon

enum FixedSampleSizeRechunker {
    private static let maxSampleSize = 8 * 1024

    struct Results {
        let offsets: [Int]
        let sizes: [Int]
        let maximumSize: Int
        let timestamps: [Int64]
        let flags: [SampleFlags]
        let duration: Int64
        let totalSize: Int
    }

    static func rechunk(
        fixedSampleSize: Int,
        chunkOffsets: [Int],
        chunkSampleCounts: [Int],
        timestampDeltaInTimeUnits: Int64
    ) -> Results {
        let maxSampleCount = maxSampleSize / fixedSampleSize

        var offsets = [Int]()
        var sizes = [Int]()
        var timestamps = [Int64]()
        var flags = [SampleFlags]()
        var maximumSize = 0
        var totalSize = 0
        var originalSampleIndex = 0

        for (chunkOffset, chunkSampleCount) in zip(chunkOffsets, chunkSampleCounts) {
            var samplesRemaining = chunkSampleCount
            var sampleOffset = chunkOffset

            while samplesRemaining > 0 {
                let bufferSampleCount = min(maxSampleCount, samplesRemaining)
                let bufferSize = fixedSampleSize * bufferSampleCount

                offsets.append(sampleOffset)
                sizes.append(bufferSize)
                timestamps.append(timestampDeltaInTimeUnits * Int64(originalSampleIndex))
                flags.append(.keyframe)

                totalSize += bufferSize
                maximumSize = max(maximumSize, bufferSize)
                sampleOffset += bufferSize
                originalSampleIndex += bufferSampleCount
                samplesRemaining -= bufferSampleCount
            }
        }

        return Results(
            offsets: offsets,
            sizes: sizes,
            maximumSize: maximumSize,
            timestamps: timestamps,
            flags: flags,
            duration: timestampDeltaInTimeUnits * Int64(originalSampleIndex),
            totalSize: totalSize
        )
    }
}
