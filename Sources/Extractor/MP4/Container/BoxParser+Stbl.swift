//
//  BoxParser+Stbl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

extension BoxParser {
    func parseStbl(
        track: inout Track,
        stblBox: ContainerBox,
        gaplessInfoHolder: inout GaplessInfoHolder,
        omitTrackSampleTable: Bool
    ) throws -> TrackSampleTable {
        var sampleSizeBox: SampleSizeBox = if let stszAtom = stblBox.getLeafBoxOfType(type: .stsz) {
            try StszSampleSizeBox(stszAtom: stszAtom)
        } else if let stz2Atom = stblBox.getLeafBoxOfType(type: .stz2) {
            try Stz2SampleSizeBox(stszAtom: stz2Atom)
        } else {
            throw BoxParserErrors.badBoxContent(
                type: .stbl, reason: "Track has no sample table size information"
            )
        }

        var sampleCount = sampleSizeBox.sampleCount
        if sampleCount == 0 {
            return try .empty(track: track)
        }

        let trackTimescale = CMTimeScale(track.timescale)
        let movieTimescale = CMTimeScale(track.movieTimescale)

        /// Create a CMTime in track timescale from raw time-units.
        func trackTime(_ value: CMTimeValue) -> CMTime {
            CMTime(value: value, timescale: trackTimescale)
        }
        /// Create a CMTime in movie timescale from raw time-units.
        func movieTime(_ value: CMTimeValue) -> CMTime {
            CMTime(value: value, timescale: movieTimescale)
        }

        if track.type == .video, track.mediaDuration.isValid, track.mediaDurationUs > 0 {
            let frameRate = Float(sampleCount) / (Float(track.mediaDurationUs) / 1_000_000)
            track.format = track.format.buildUpon().setFrameRate(frameRate).build()
        }

        // Entries are byte offsets of chunks.
        var chunkOffsetsType: any FixedWidthInteger.Type = UInt32.self
        let chunkOffsetsAtom: LeafBox
        if let stcoBox = stblBox.getLeafBoxOfType(type: .stco) {
            chunkOffsetsAtom = stcoBox
        } else {
            chunkOffsetsType = UInt64.self
            chunkOffsetsAtom = try stblBox.getLeafBoxOfType(type: .co64)
                .checkNotNil(BoxParserErrors.missingBox(type: .stco))
        }

        let chunkOffsets = chunkOffsetsAtom.data
        // Entries are (chunk number, number of samples per chunk, sample description index).
        let stsc = try stblBox.getLeafBoxOfType(type: .stsc)
            .checkNotNil(BoxParserErrors.missingBox(type: .stsc)).data
        // Entries are (number of samples, timestamp delta between those samples).
        var stts = try stblBox.getLeafBoxOfType(type: .stts)
            .checkNotNil(BoxParserErrors.missingBox(type: .stts)).data
        // Entries are the indices of samples that are synchronization samples.
        var stss = stblBox.getLeafBoxOfType(type: .stss)?.data
        // Entries are (number of samples, timestamp offset).
        var ctts = stblBox.getLeafBoxOfType(type: .ctts)?.data

        // Prepare to read chunk information.
        var chunkIterator = try ChunkIterator(
            stsc: stsc, chunkOffsets: chunkOffsets, chunkOffsetsType: chunkOffsetsType
        )

        // Prepare to read sample timestamps.
        stts.moveReaderIndex(to: MP4Box.fullHeaderSize)
        var remainingTimestampDeltaChanges = try stts.readInt(as: UInt32.self) - 1
        var remainingSamplesAtTimestampDelta = try stts.readInt(as: UInt32.self)
        var timestampDeltaInTimeUnits = try Int64(stts.readInt(as: UInt32.self))

        // Prepare to read sample timestamp offsets, if ctts is present.
        var remainingSamplesAtTimestampOffset: UInt32 = 0
        var remainingTimestampOffsetChanges: UInt32 = 0
        var timestampOffset: Int64 = 0
        try ctts.withTransform { ctts in
            ctts.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingTimestampOffsetChanges = try ctts.readInt(as: UInt32.self)
        }

        var nextSynchronizationSampleIndex: Int?
        var remainingSynchronizationSamples: UInt32 = 1

        if var stssBox = stss {
            stssBox.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingSynchronizationSamples = try stssBox.readInt(as: UInt32.self)
            if remainingSynchronizationSamples > 0 {
                nextSynchronizationSampleIndex = try Int(stssBox.readInt(as: UInt32.self)) - 1
                stss = stssBox
            } else {
                // Ignore empty stss boxes, which causes all samples to be treated as sync samples.
                stss = nil
            }
        }

        // TODO: Fixed sample size raw audio may need to be rechunked
        let fixedSampleSize = sampleSizeBox.fixedSampleSize
        let sampleMimeType = track.format.sampleMimeType
        let rechunkFixedSizeSamples = fixedSampleSize != nil
            && ([.audioRAW, .audioMLAW, .audioALAW].contains(sampleMimeType))
            && remainingTimestampDeltaChanges == 0
            && remainingTimestampOffsetChanges == 0
            && remainingSynchronizationSamples == 0

        var offsets = [Int]()
        var sizes = [Int]()
        var maximumSize = 0
        var ptsValues = [CMTime]()
        var dtsValues = [CMTime]()
        var sampleDurations = [CMTime]()
        var samplesFlags = [SampleFlags]()
        var syncSampleIndicesList = [Int]()
        let hasOnlySyncSamples = stss == nil
        var dtsAccumulator: Int64 = 0       // running DTS in track timescale units
        var totalDuration = CMTime.zero     // total duration in track timescale
        var totalSize = 0

        if rechunkFixedSizeSamples, let fixedSampleSize {
            var chunkOffsetsBytes = Array(repeating: 0, count: chunkIterator.length)
            var chunkSampleCounts = Array(repeating: 0, count: chunkIterator.length)
            while try chunkIterator.moveNext() {
                chunkOffsetsBytes[chunkIterator.index] = chunkIterator.offset
                chunkSampleCounts[chunkIterator.index] = chunkIterator.numberOfSamples
            }
            let r = FixedSampleSizeRechunker.rechunk(
                fixedSampleSize: fixedSampleSize,
                chunkOffsets: chunkOffsetsBytes,
                chunkSampleCounts: chunkSampleCounts,
                timestampDeltaInTimeUnits: timestampDeltaInTimeUnits
            )
            sampleCount = r.offsets.count
            offsets = omitTrackSampleTable ? [] : r.offsets
            sizes = omitTrackSampleTable ? [] : r.sizes
            samplesFlags = omitTrackSampleTable ? [] : r.flags
            maximumSize = r.maximumSize
            totalSize = r.totalSize
            totalDuration = trackTime(r.duration)

            if !omitTrackSampleTable {
                let uniformDelta = trackTime(timestampDeltaInTimeUnits)
                // No ctts for rechunked fixed-size audio ⇒ DTS == PTS, uniform delta.
                ptsValues = r.timestamps.map { trackTime($0) }
                dtsValues = ptsValues
                sampleDurations = Array(repeating: uniformDelta, count: sampleCount)
                // Last sample: remaining duration.
                if sampleCount > 0 {
                    sampleDurations[sampleCount - 1] = totalDuration - dtsValues[sampleCount - 1]
                }
            } else {
                ptsValues = []
                dtsValues = []
                sampleDurations = []
            }
        } else {
            offsets = omitTrackSampleTable ? [] : Array(repeating: 0, count: sampleCount)
            sizes = omitTrackSampleTable ? [] : Array(repeating: 0, count: sampleCount)
            ptsValues = omitTrackSampleTable ? [] : Array(repeating: .zero, count: sampleCount)
            dtsValues = omitTrackSampleTable ? [] : Array(repeating: .zero, count: sampleCount)
            sampleDurations = omitTrackSampleTable ? [] : Array(repeating: .zero, count: sampleCount)
            samplesFlags = omitTrackSampleTable ? [] : Array(repeating: [], count: sampleCount)
            var offset = 0
            var remainingSamplesInChunk = 0

            for index in 0..<sampleCount {
                var chunkDataComplete = true
                // Advance to the next chunk if necessary.
                while remainingSamplesInChunk == 0 {
                    chunkDataComplete = try chunkIterator.moveNext()
                    guard chunkDataComplete else { break }
                    offset = chunkIterator.offset
                    remainingSamplesInChunk = chunkIterator.numberOfSamples
                }

                if !chunkDataComplete {
                    // TODO: log Unexpected end of chunk data
                    sampleCount = index
                    if !omitTrackSampleTable {
                        offsets = Array(offsets[0..<sampleCount])
                        sizes = Array(sizes[0..<sampleCount])
                        ptsValues = Array(ptsValues[0..<sampleCount])
                        dtsValues = Array(dtsValues[0..<sampleCount])
                        sampleDurations = Array(sampleDurations[0..<sampleCount])
                        samplesFlags = Array(samplesFlags[0..<sampleCount])
                    }
                    break
                }

                // Add on the timestamp offset if ctts is present.
                try ctts.withTransform { ctts in
                    while remainingSamplesAtTimestampOffset == 0 && remainingTimestampOffsetChanges > 0 {
                        remainingSamplesAtTimestampOffset = try ctts.readInt(as: UInt32.self)
                        // The BMFF spec (ISO/IEC 14496-12) states that sample offsets should be unsigned
                        // integers in version 0 ctts boxes, however some streams violate the spec and use
                        // signed integers instead. It's safe to always decode sample offsets as signed integers
                        // here, because unsigned integers will still be parsed correctly (unless their top bit
                        // is set, which is never true in practice because sample offsets are always small).
                        timestampOffset = try CMTimeValue(ctts.readInt(as: Int32.self))
                        remainingTimestampOffsetChanges -= 1
                    }
                    remainingSamplesAtTimestampOffset -= 1
                }

                let currentSampleSize = try sampleSizeBox.readNextSampleSize()
                totalSize += currentSampleSize
                if currentSampleSize > maximumSize {
                    maximumSize = currentSampleSize
                }

                if !omitTrackSampleTable {
                    offsets[index] = offset
                    sizes[index] = currentSampleSize
                    // DTS is the raw accumulation from stts deltas.
                    dtsValues[index] = trackTime(dtsAccumulator)
                    // PTS = DTS + composition offset from ctts.
                    ptsValues[index] = trackTime(dtsAccumulator + timestampOffset)
                    // Per-sample duration = current stts delta (refined below for last sample).
                    sampleDurations[index] = trackTime(timestampDeltaInTimeUnits)
                    // All samples are synchronization samples if the stss is not present.
                    samplesFlags[index] = stss == nil ? .keyframe : []
                    if index == nextSynchronizationSampleIndex {
                        samplesFlags[index] = [.keyframe]
                        syncSampleIndicesList.append(index)
                    }
                }

                if index == nextSynchronizationSampleIndex {
                    remainingSynchronizationSamples -= 1
                    if remainingSynchronizationSamples > 0 {
                        var stssBox = try stss.checkNotNil(BoxParserErrors.missingBox(type: .stss))
                        nextSynchronizationSampleIndex = try Int(stssBox.readInt(as: UInt32.self)) - 1
                        stss = stssBox
                    }
                }

                // Add on the duration of this sample.
                dtsAccumulator += timestampDeltaInTimeUnits
                remainingSamplesAtTimestampDelta -= 1
                if remainingSamplesAtTimestampDelta == 0 && remainingTimestampDeltaChanges > 0 {
                    remainingSamplesAtTimestampDelta = try stts.readInt(as: UInt32.self)
                    // The BMFF spec (ISO/IEC 14496-12) states that sample deltas should be unsigned integers
                    // in stts boxes, however some streams violate the spec and use signed integers instead.
                    // It's safe to always decode sample deltas as signed integers here,
                    // because unsigned integers will still be parsed correctly
                    // (unless their top bit is set, which is never true in practice because sample
                    // deltas are always small).
                    timestampDeltaInTimeUnits = try Int64(stts.readInt(as: Int32.self))
                    remainingTimestampDeltaChanges -= 1
                }

                offset += currentSampleSize
                remainingSamplesInChunk -= 1
            }

            totalDuration = trackTime(dtsAccumulator + timestampOffset)

            // Refine last sample duration: total_dts_accumulation - last_dts.
            if !omitTrackSampleTable, sampleCount > 0 {
                sampleDurations[sampleCount - 1] = trackTime(dtsAccumulator) - dtsValues[sampleCount - 1]
            }

            // If the stbl's child boxes are not consistent the container is malformed, but the stream may
            // still be playable.
            var isCttsValid = true
            try ctts.withTransform { ctts in
                while remainingTimestampOffsetChanges > 0 {
                    if try ctts.readInt(as: UInt32.self) > 0 {
                        isCttsValid = false
                        break
                    }
                    try ctts.readInt(as: Int32.self)
                    remainingTimestampOffsetChanges -= 1
                }
            }

            if remainingSynchronizationSamples != 0
                || remainingSamplesAtTimestampDelta != 0
                || remainingSamplesInChunk != 0
                || remainingTimestampDeltaChanges != 0
                || remainingSamplesAtTimestampOffset != 0
                || !isCttsValid {
    //            fatalError()
                // Inconsistent stbl box for track
            }
        }

        if track.mediaDuration.isValid, track.mediaDurationUs > 0 {
            let averageBitrate = Util.scaleLargeValue(
                Int64(totalSize * 8),
                multiplier: .microsecondsPerSecond,
                divisor: track.mediaDurationUs,
                roundingMode: .down
            )
            if averageBitrate > 0, averageBitrate < .max {
                let format = track.format.buildUpon().setAverageBitrate(Int(averageBitrate)).build()
                track.format = format
            }
        }

        guard let editListDurations = track.editListDurations,
              let editListMediaTimes = track.editListMediaTimes else {
            return try TrackSampleTable(
                track: track,
                offsets: offsets,
                sizes: sizes,
                maximumSize: maximumSize,
                pts: ptsValues,
                dts: dtsValues,
                durations: sampleDurations,
                duration: totalDuration,
                flags: samplesFlags,
                syncSampleIndices: syncSampleIndicesList,
                hasOnlySyncSamples: hasOnlySyncSamples,
                sampleCount: sampleCount
            )
        }

        if omitTrackSampleTable {
            let editedDuration: CMTime
            if editListDurations.count == 1 && editListDurations[0] == 0 {
                let editStartTime = trackTime(editListMediaTimes[0])
                editedDuration = totalDuration - editStartTime
            } else {
                let movieTicks = editListDurations.indices
                    .filter { editListMediaTimes[$0] != -1 }
                    .reduce(Int64.zero) { $0 + editListDurations[$1] }
                editedDuration = movieTime(movieTicks)
            }

            return try TrackSampleTable(
                track: track,
                offsets: [],
                sizes: [],
                maximumSize: maximumSize,
                pts: [],
                dts: [],
                durations: [],
                duration: editedDuration,
                flags: [],
                syncSampleIndices: [],
                hasOnlySyncSamples: hasOnlySyncSamples,
                sampleCount: sampleCount
            )
        }

        // See the BMFF spec (ISO/IEC 14496-12) subsection 8.6.6. Edit lists that require prerolling
        // from a sync sample after reordering are not supported. Partial audio sample truncation is
        // only supported in edit lists with one edit that removes less than
        // maxGaplessTrimSizeSamples samples from the start/end of the track. This implementation
        // handles simple discarding/delaying of samples. The extractor may place further restrictions
        // on what edited streams are playable.

        if editListDurations.count == 1, track.type == .audio, ptsValues.count >= 2 {
            let editStartTime = trackTime(editListMediaTimes[0])
            let editListDuration = movieTime(editListDurations[0])
            let editEndTime = editStartTime + CMTimeConvertScale(
                editListDuration, timescale: trackTimescale, method: .default
            )

            if canApplyEditWithGaplessInfo(
                pts: ptsValues,
                duration: totalDuration,
                editStartTime: editStartTime,
                editEndTime: editEndTime
            ) {
                let paddingDuration = totalDuration - editEndTime
                let sampleRateTimescale = CMTimeScale(track.format.sampleRate)

                let encoderDelay = (editStartTime - ptsValues[0])
                    .convertScale(sampleRateTimescale, method: .default).value
                let encoderPadding = paddingDuration
                    .convertScale(sampleRateTimescale, method: .default).value

                if (encoderDelay != 0 || encoderPadding != 0),
                   encoderDelay <= .max, encoderPadding <= .max {
                    gaplessInfoHolder = .init(
                        encoderDelay: Int(encoderDelay),
                        encoderPadding: Int(encoderPadding)
                    )

                    return try TrackSampleTable(
                        track: track,
                        offsets: offsets,
                        sizes: sizes,
                        maximumSize: maximumSize,
                        pts: ptsValues,
                        dts: dtsValues,
                        durations: sampleDurations,
                        duration: editListDuration,
                        flags: samplesFlags,
                        syncSampleIndices: syncSampleIndicesList,
                        hasOnlySyncSamples: hasOnlySyncSamples,
                        sampleCount: sampleCount
                    )
                }
            }
        }

        if editListDurations.count == 1, editListDurations[0] == 0 {
            // The current version of the spec leaves handling of an edit with zero segment_duration in
            // unfragmented files open to interpretation. We handle this as a special case and include all
            // samples in the edit.
            let editStartTime = trackTime(editListMediaTimes[0])
            let editedDuration = totalDuration - editStartTime

            let editedPts = ptsValues.map { $0 - editStartTime }
            let editedDts = dtsValues.map { $0 - editStartTime }
            // Per-sample durations are unaffected by a uniform shift.

            return try TrackSampleTable(
                track: track,
                offsets: offsets,
                sizes: sizes,
                maximumSize: maximumSize,
                pts: editedPts,
                dts: editedDts,
                durations: sampleDurations,
                duration: editedDuration,
                flags: samplesFlags,
                syncSampleIndices: syncSampleIndicesList,
                hasOnlySyncSamples: hasOnlySyncSamples,
                sampleCount: sampleCount
            )
        }

        // When applying edit lists, we need to include any partial clipped samples at the end to ensure
        // the final output is rendered correctly.
        // For audio only, we can omit any sample that starts at exactly the end point of an edit as
        // there is no partial audio in this case.
        let omitZeroDurationClippedSample = track.type == .audio

        // We need a comparable Int64 array for binary searches during edit list application.
        // All PTS share trackTimescale, so raw .value comparison is valid.
        let ptsRawValues = ptsValues.map { $0.value }

        // Count the number of samples after applying edits.
        var editedSampleCount = 0
        var nextSampleIndex = 0
        var copyMetadata = false
        var startIndices = Array(repeating: 0, count: editListDurations.count)
        var endIndices = Array(repeating: 0, count: editListDurations.count)

        for (index, (editMediaTimeRaw, editListDurationRaw)) in
            zip(editListMediaTimes, editListDurations).enumerated()
        {
            guard editMediaTimeRaw != -1 else { continue }

            let editDuration = CMTimeConvertScale(
                movieTime(editListDurationRaw), timescale: trackTimescale, method: .default
            )
            let editEndTimeRaw = editMediaTimeRaw + editDuration.value

            // The timestamps array is in the order read from the media, which might not be strictly
            // sorted. However, all sync frames are guaranteed to be in order. The logic below
            // searches for the true start and end of the edit, accounting for out-of-order frames.

            // The startIndices calculation finds the sample at or just before the edit start time.
            // It then walks backward to ensure the index points to a sync frame, since
            // decoding must start from a keyframe.
            startIndices[index] = Util.binarySearch(
                array: ptsRawValues,
                value: editMediaTimeRaw,
                inclusive: true,
                stayInBounds: true
            )

            // The endIndices calculation finds the true end of the edit by searching past the
            // naive end point for any out-of-order frames that belong in the clip.
            let firstSampleAfterEdit = Util.binarySearchCeil(
                array: ptsRawValues,
                value: editEndTimeRaw,
                inclusive: omitZeroDurationClippedSample,
                stayInBounds: false
            )

            // To account for out-of-order frames, we use a search that continues until we have seen
            // more out-of-boundary frames than the reorder limit (maxNumReorderSamples), which
            // guarantees no more valid frames will be found.
            var samplesSeenAfterEnd = 0
            var maxValidIndexInWindow = firstSampleAfterEdit - 1
            for j in firstSampleAfterEdit..<ptsRawValues.count {
                if ptsRawValues[j] < editEndTimeRaw {
                    // This is an out-of-order frame that belongs in the edit. Update our max index.
                    maxValidIndexInWindow = j
                } else {
                    // This frame is outside the edit. Increment our counter of seen "post-roll" frames.
                    samplesSeenAfterEnd += 1
                    if samplesSeenAfterEnd > track.format.maxNumReorderSamples {
                        // We've exhausted our search budget. We can be sure no more valid frames will appear.
                        break
                    }
                }
            }
            endIndices[index] = maxValidIndexInWindow + 1

            // Ensure we start decoding from a sync frame by searching backwards.
            let initialStartIndex = startIndices[index]
            while startIndices[index] > 0 && !samplesFlags[startIndices[index]].contains(.keyframe) {
                startIndices[index] -= 1
            }

            // If we searched all the way back and didn't find a sync frame, search forward from the
            // original start.
            if startIndices[index] == 0 && !samplesFlags[0].contains(.keyframe) {
                startIndices[index] = initialStartIndex
                while startIndices[index] < endIndices[index] && !samplesFlags[startIndices[index]].contains(.keyframe) {
                    startIndices[index] += 1
                }
            }

            editedSampleCount += endIndices[index] - startIndices[index]
            copyMetadata = copyMetadata || nextSampleIndex != startIndices[index]
            nextSampleIndex = endIndices[index]
        }
        copyMetadata = copyMetadata || editedSampleCount != sampleCount

        // Calculate edited sample timestamps and update the corresponding metadata arrays.
        var editedOffsets = copyMetadata ? Array(repeating: 0, count: editedSampleCount) : offsets
        var editedSizes = copyMetadata ? Array(repeating: 0, count: editedSampleCount) : sizes
        var editedMaximumSize = copyMetadata ? 0 : maximumSize
        var editedFlags = copyMetadata
            ? Array(repeating: SampleFlags(), count: editedSampleCount) : samplesFlags
        var editedSyncSampleIndicesList = copyMetadata ? [Int]() : syncSampleIndicesList
        var editedPts = copyMetadata
            ? Array(repeating: CMTime.zero, count: editedSampleCount) : ptsValues
        var editedDts = copyMetadata
            ? Array(repeating: CMTime.zero, count: editedSampleCount) : dtsValues
        var editedDurations = copyMetadata
            ? Array(repeating: CMTime.zero, count: editedSampleCount) : sampleDurations

        var moviePtsAccumulator = CMTime.zero
        var sampleIndex = 0
        var hasPrerollSamples = false

        for (index, editMediaTimeRaw) in editListMediaTimes.enumerated() {
            guard editMediaTimeRaw != -1 else {
                moviePtsAccumulator = moviePtsAccumulator + movieTime(editListDurations[index])
                continue
            }

            let editMediaTime = trackTime(editMediaTimeRaw)
            let startIndex = startIndices[index]
            let endIndex = endIndices[index]

            if copyMetadata {
                let count = endIndex - startIndex
                editedOffsets.replaceSubrange(sampleIndex..<sampleIndex + count,
                                              with: offsets[startIndex..<endIndex])
                editedSizes.replaceSubrange(sampleIndex..<sampleIndex + count,
                                            with: sizes[startIndex..<endIndex])
                editedFlags.replaceSubrange(sampleIndex..<sampleIndex + count,
                                            with: samplesFlags[startIndex..<endIndex])
                editedDurations.replaceSubrange(sampleIndex..<sampleIndex + count,
                                                with: sampleDurations[startIndex..<endIndex])
            }

            for j in startIndex..<endIndex {
                // PTS in edit timeline = movie_pts_offset + (original_pts - edit_media_time)
                let timeInSegment = ptsValues[j] - editMediaTime
                editedPts[sampleIndex] = moviePtsAccumulator + timeInSegment

                // DTS in edit timeline = movie_pts_offset + (original_dts - edit_media_time)
                let dtsInSegment = dtsValues[j] - editMediaTime
                editedDts[sampleIndex] = moviePtsAccumulator + dtsInSegment

                if timeInSegment < .zero { hasPrerollSamples = true }

                if copyMetadata, editedSizes[sampleIndex] > editedMaximumSize {
                    editedMaximumSize = sizes[j]
                }
                if copyMetadata, !hasOnlySyncSamples, editedFlags[sampleIndex].contains(.keyframe) {
                    editedSyncSampleIndicesList.append(sampleIndex)
                }
                sampleIndex += 1
            }
            moviePtsAccumulator = moviePtsAccumulator + movieTime(editListDurations[index])
        }

        let editedDuration = moviePtsAccumulator
        if hasPrerollSamples {
            let newFormat = track.format.buildUpon().setHasPrerollSamples(true).build()
            track.format = newFormat
        }

        return try TrackSampleTable(
            track: track,
            offsets: editedOffsets,
            sizes: editedSizes,
            maximumSize: editedMaximumSize,
            pts: editedPts,
            dts: editedDts,
            durations: editedDurations,
            duration: editedDuration,
            flags: editedFlags,
            syncSampleIndices: editedSyncSampleIndicesList,
            hasOnlySyncSamples: hasOnlySyncSamples,
            sampleCount: editedOffsets.count
        )
    }

    private func canApplyEditWithGaplessInfo(
        pts: [CMTime],
        duration: CMTime,
        editStartTime: CMTime,
        editEndTime: CMTime
    ) -> Bool {
        let lastIndex = pts.count - 1
        let latestDelayIndex = max(0, min(.maxGaplessTrimSizeSamples, lastIndex))
        let earliestPaddingIndex = max(0, min(pts.count - .maxGaplessTrimSizeSamples, lastIndex))

        return pts[0] <= editEndTime
            && editStartTime < pts[latestDelayIndex]
            && pts[earliestPaddingIndex] < editEndTime
            && editEndTime <= duration
    }
}

// MARK: - SampleSizeBox

private extension BoxParser {
    private protocol SampleSizeBox {
        var sampleCount: Int { get }
        var fixedSampleSize: Int? { get }
        mutating func readNextSampleSize() throws -> Int
    }

    struct StszSampleSizeBox: SampleSizeBox {
        let fixedSampleSize: Int?
        let sampleCount: Int
        private var data: ByteBuffer

        init(stszAtom: LeafBox) throws {
            data = stszAtom.data
            data.moveReaderIndex(to: MP4Box.fullHeaderSize)
            let sampleSize = try data.readInt(as: UInt32.self)
            fixedSampleSize = sampleSize == 0 ? nil : Int(sampleSize)
            sampleCount = try Int(data.readInt(as: UInt32.self))
        }
        
        mutating func readNextSampleSize() throws -> Int {
            if let fixedSampleSize {
                return fixedSampleSize
            } else {
                return try Int(data.readInt(as: UInt32.self))
            }
        }
    }

    struct Stz2SampleSizeBox: SampleSizeBox {
        let fixedSampleSize: Int?
        let sampleCount: Int
        private let fieldSize: Int
        private var data: ByteBuffer

        private var sampleIndex = 0
        private var currentByte = 0

        init(stszAtom: LeafBox) throws {
            data = stszAtom.data
            data.moveReaderIndex(to: MP4Box.fullHeaderSize)
            fixedSampleSize = nil
            fieldSize = try Int(data.readInt(as: UInt32.self)) & 0x000000FF
            sampleCount = try Int(data.readInt(as: UInt32.self))
        }

        mutating func readNextSampleSize() throws -> Int {
            if fieldSize == 8 {
                return try Int(data.readInt(as: UInt8.self))
            } else if fieldSize == 16 {
                return try Int(data.readInt(as: UInt16.self))
            } else { // fieldSize == 4.
                sampleIndex += 1
                if sampleIndex % 2 == 0 {
                    // Read the next byte into our cached byte when we are reading the upper bits.
                    currentByte = try Int(data.readInt(as: UInt8.self))
                    return (currentByte & 0xF0) >> 4
                } else {
                    // Mask out the upper 4 bits of the last byte we read.
                    return currentByte & 0x0F
                }
            }
        }
    }
}

// MARK: - ChunkIterator

private extension BoxParser {
    struct ChunkIterator {
        let length: Int
        var index = -1
        var offset = 0
        var numberOfSamples = 0

        private var stsc: ByteBuffer
        private var chunkOffsets: ByteBuffer
        private let chunkOffsetsType: any FixedWidthInteger.Type

        private var remainingSamplesPerChunkChanges: Int
        private var nextSamplesPerChunkChangeIndex: Int? = 0

        init(stsc: ByteBuffer, chunkOffsets: ByteBuffer, chunkOffsetsType: any FixedWidthInteger.Type) throws {
            self.stsc = stsc
            self.chunkOffsets = chunkOffsets
            self.chunkOffsetsType = chunkOffsetsType
            self.chunkOffsets.moveReaderIndex(to: MP4Box.fullHeaderSize)
            length = try Int(self.chunkOffsets.readInt(as: UInt32.self))
            self.stsc.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingSamplesPerChunkChanges = try Int(self.stsc.readInt(as: UInt32.self))
            guard try self.stsc.readInt(as: UInt32.self) == 1 else {
                throw BoxParserErrors.badBoxContent(type: .stsc, reason: "first_chunk must be 1")
            }
        }

        mutating func moveNext() throws -> Bool {
            index += 1
            if index == length {
                return false
            }

            offset = try Int(chunkOffsets.readInt(as: chunkOffsetsType))
            if index == nextSamplesPerChunkChangeIndex {
                numberOfSamples = try Int(stsc.readInt(as: UInt32.self))
                stsc.moveReaderIndex(forwardBy: 4) // Skip sample_description_index
                remainingSamplesPerChunkChanges -= 1
                nextSamplesPerChunkChangeIndex = if remainingSamplesPerChunkChanges > 0 {
                    try Int(stsc.readInt(as: UInt32.self) - 1)
                } else {
                    nil
                }
            }
            return true
        }
    }
}

private extension Int {
    static let maxGaplessTrimSizeSamples = 4
}
