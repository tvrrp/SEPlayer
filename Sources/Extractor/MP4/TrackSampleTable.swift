//
//  TrackSampleTable.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp4.TrackSampleTable
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// The sample table of an MP4 track, built from its `stbl` box.
public struct TrackSampleTable {
    // A long movie has hundreds of thousands of samples, so each field is stored compactly: times as values of one
    // timescale rather than `CMTime`s, sizes in 32 bits, and decode times sharing the presentation times when they
    // are the same, as for audio.

    public let track: Track
    public let sampleCount: Int
    public let offsets: [Int]
    public let sizes: SampleSizes
    public let maximumSize: Int

    public let pts: SampleTimes
    public let dts: SampleTimes
    public let durations: SampleTimes
    public let duration: CMTime

    public let flags: [SampleProperties.Flags]
    public let syncSampleIndices: [Int]
    public let hasOnlySyncSamples: Bool
    /// The attributes of the samples that have any, such as the trims of the audio samples an edit cuts.
    public let attributes: [Int: SampleAttributes]

    init(
        track: Track,
        offsets: [Int],
        sizes: [Int],
        maximumSize: Int,
        pts: [CMTime],
        dts: [CMTime],
        durations: [CMTime],
        duration: CMTime,
        flags: [SampleProperties.Flags],
        syncSampleIndices: [Int],
        hasOnlySyncSamples: Bool,
        sampleCount: Int,
        attributes: [Int: SampleAttributes] = [:]
    ) throws {
        try checkArgument(sizes.count == sampleCount)
        try checkArgument(offsets.count == sampleCount)
        try checkArgument(flags.count == sampleCount)
        try checkArgument(pts.count == sampleCount)
        try checkArgument(dts.count == sampleCount)
        try checkArgument(durations.count == sampleCount)

        self.track = track
        self.offsets = offsets
        self.sizes = try SampleSizes(sizes)
        self.maximumSize = maximumSize
        let timescale = SampleTimes.commonTimescale(of: [pts, dts, durations], preferring: track.timescale)
        let presentationTimes = SampleTimes(pts, timescale: timescale)
        self.pts = presentationTimes
        // Without composition offsets, decode times are the presentation times: they share their storage.
        self.dts = dts == pts ? presentationTimes : SampleTimes(dts, timescale: timescale)
        self.durations = SampleTimes(durations, timescale: timescale)
        self.duration = duration
        self.syncSampleIndices = syncSampleIndices
        self.hasOnlySyncSamples = hasOnlySyncSamples
        self.sampleCount = sampleCount
        self.attributes = attributes

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

    /// The sample to read from for the sample at `sampleIndex` to decode right: compressed audio needs the packet
    /// before it, and the packets before that one which an edit cuts whole, as an encoder's delay is.
    func decodeStartIndex(for sampleIndex: Int) -> Int {
        guard track.type == .audio, track.format.sampleMimeType != .audioRAW else {
            return sampleIndex
        }
        var index = max(0, sampleIndex - 1)
        while index > 0, let attributes = attributes[index - 1],
              attributes.trimAtStart + attributes.trimAtEnd >= durations[index - 1] {
            index -= 1
        }
        return index
    }

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

    @inline(__always)
    func timingInfo(at index: Int) -> CMSampleTimingInfo {
        CMSampleTimingInfo(
            duration: durations[index],
            presentationTimeStamp: pts[index],
            decodeTimeStamp: dts[index]
        )
    }
}

/// Times of samples as values of one timescale: 8 bytes each, rather than a `CMTime`'s 24.
public struct SampleTimes: RandomAccessCollection, Equatable, Sendable {
    public let values: [Int64]
    public let timescale: CMTimeScale

    public var startIndex: Int { 0 }
    public var endIndex: Int { values.count }

    public subscript(position: Int) -> CMTime {
        CMTime(value: values[position], timescale: timescale)
    }

    /// - Parameter timescale: The timescale of the values; times of another one are converted, rounded.
    init(_ times: [CMTime], timescale: CMTimeScale) {
        self.timescale = timescale
        values = times.map { time in
            time.timescale == timescale ? time.value : CMTimeConvertScale(time, timescale: timescale, method: .roundHalfAwayFromZero).value
        }
    }

    /// The timescale that keeps the times exact: `preferred` when they all have it, as the times of a track have its
    /// own, otherwise the finest of theirs.
    static func commonTimescale(of times: [[CMTime]], preferring preferred: CMTimeScale) -> CMTimeScale {
        var finest = preferred
        var isUniform = true
        for list in times {
            for time in list where time.timescale != preferred {
                isUniform = false
                finest = Swift.max(finest, time.timescale)
            }
        }
        return isUniform ? preferred : finest
    }
}

/// Sizes of samples in 32 bits, read as `Int`.
public struct SampleSizes: RandomAccessCollection, Sendable {
    public let values: [UInt32]

    public var startIndex: Int { 0 }
    public var endIndex: Int { values.count }

    public subscript(position: Int) -> Int {
        Int(values[position])
    }

    init(_ sizes: [Int]) throws {
        values = try sizes.map { size in
            let value = UInt32(exactly: size)
            try checkArgument(value != nil)
            return value ?? 0
        }
    }
}
