//
//  FixedSampleSizeRechunker.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.FixedSampleSizeRechunker
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

enum FixedSampleSizeRechunker {
    private static let maxSampleSize = 8 * 1024

    struct Results {
        let offsets: [Int]
        let sizes: [Int]
        let maximumSize: Int
        let timestamps: [Int64]
        let flags: [SampleProperties.Flags]
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
        var flags = [SampleProperties.Flags]()
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
