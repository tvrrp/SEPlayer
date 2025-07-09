//
//  BoxParser+Stbl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime

extension BoxParser {
    func parseStbl(track: inout Track, stblBox: ContainerBox, gaplessInfoHolder: inout GaplessInfoHolder) throws -> TrackSampleTable {
        var sampleSizeBox: SampleSizeBox = if let stszAtom = stblBox.getLeafBoxOfType(type: .stsz) {
            try StszSampleSizeBox(stszAtom: stszAtom)
        } else if let stz2Atom = stblBox.getLeafBoxOfType(type: .stz2) {
            try Stz2SampleSizeBox(stszAtom: stz2Atom)
        } else {
            throw BoxParserErrors.badBoxContent(
                type: .stbl, reason: "Track has no sample table size information"
            )
        }

        let sampleCount = sampleSizeBox.sampleCount
        if sampleCount == 0 {
            return TrackSampleTable(track: track, maximumSize: 0, durationUs: .zero, samples: [])
        }

        if track.type == .video, track.mediaDurationUs > 0 {
            let frameRate = Float(sampleCount) / ((Float(track.mediaDurationUs) / 1000000))
            track.format2 = track.format2.buildUpon().setFrameRate(frameRate).build()
        }

        // Entries are byte offsets of chunks.
        var chunkOffsetsType: any FixedWidthInteger.Type = UInt32.self
        let chunkOffsetsAtom: LeafBox
        if let stblBox = stblBox.getLeafBoxOfType(type: .stco) {
            chunkOffsetsAtom = stblBox
        } else {
            chunkOffsetsType = UInt64.self
            chunkOffsetsAtom = try stblBox.getLeafBoxOfType(type: .co64)
                .checkNotNil(BoxParserErrors.missingBox(type: .stco))
        }

        let chunkOffsets = chunkOffsetsAtom.data
        // Entries are (chunk number, number of samples per chunk, sample description index).
        let stsc = try stblBox.getLeafBoxOfType(type: .stsc).checkNotNil(BoxParserErrors.missingBox(type: .stsc)).data
        // Entries are (number of samples, timestamp delta between those samples).
        var stts = try stblBox.getLeafBoxOfType(type: .stts).checkNotNil(BoxParserErrors.missingBox(type: .stts)).data
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
        var timestampDeltaInTimeUnits = try CMTimeValue(stts.readInt(as: UInt32.self))

        // Prepare to read sample timestamp offsets, if ctts is present.
        var remainingSamplesAtTimestampOffset: UInt32 = 0
        var remainingTimestampOffsetChanges: UInt32 = 0
        var timestampOffset: CMTimeValue = 0
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

        var offsets = [Int]()
        var sizes = [Int]()
        var maximumSize = 0
        var timestamps = [Int64]()
        var samplesFlags = [SampleFlags]()
        var timestampTimeUnits: Int64 = 0
        var duration: Int64 = 0

        var offset = 0
        var remainingSamplesInChunk = 0

        // TODO: if rechunkFixedSizeSamples

        for index in 0..<sampleCount {
            // Advance to the next chunk if necessary.
            while remainingSamplesInChunk == 0, try chunkIterator.moveNext() {
                offset = chunkIterator.offset
                remainingSamplesInChunk = chunkIterator.numberOfSamples
            }
            // TODO: handle chunkDataComplete == false

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

            let size = try sampleSizeBox.readNextSampleSize()
            if size > maximumSize {
                maximumSize = size
            }

            // All samples are synchronization samples if the stss is not present.
            var flags: SampleFlags = [stss == nil ? .keyframe : []]
            if index == nextSynchronizationSampleIndex {
                flags = [.keyframe]
                remainingSynchronizationSamples -= 1
                if remainingSynchronizationSamples > 0 {
                    var stssBox = try stss.checkNotNil(BoxParserErrors.missingBox(type: .stss))
                    nextSynchronizationSampleIndex = try Int(stssBox.readInt(as: UInt32.self)) - 1
                    stss = stssBox
                }
            }

            offsets.append(offset)
            sizes.append(size)
            timestamps.append(timestampTimeUnits + timestampOffset)
            samplesFlags.append(flags)

            // Add on the duration of this sample.
            timestampTimeUnits += timestampDeltaInTimeUnits
            remainingSamplesAtTimestampDelta -= 1
            if remainingSamplesAtTimestampDelta == 0 && remainingTimestampDeltaChanges > 0 {
                remainingSamplesAtTimestampDelta = try stts.readInt(as: UInt32.self)
                // The BMFF spec (ISO/IEC 14496-12) states that sample deltas should be unsigned integers
                // in stts boxes, however some streams violate the spec and use signed integers instead.
                // It's safe to always decode sample deltas as signed integers here,
                // because unsigned integers will still be parsed correctly
                // (unless their top bit is set, which is never true in practice because sample
                // deltas are always small).
                timestampDeltaInTimeUnits = try CMTimeValue(stts.readInt(as: Int32.self))
                remainingTimestampDeltaChanges -= 1
            }

            offset += size
            remainingSamplesInChunk -= 1
        }
        duration = timestampTimeUnits + timestampOffset

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

        let durationUs = Util.scaleLargeTimestamp(
            duration,
            multiplier: Int64.microsecondsPerSecond,
            divisor: track.timescale
        )

        guard let editListDurations = track.editListDurations,
              let editListMediaTimes = track.editListMediaTimes else {
            let samples = offsets.enumerated().map { index, offset in
                TrackSampleTable.Sample(
                    offset: offset,
                    size: sizes[index],
                    presentationTimeStampUs: Util.scaleLargeTimestamp(
                        timestamps[index],
                        multiplier: Int64.microsecondsPerSecond,
                        divisor: track.timescale
                    ),
                    flags: samplesFlags[index]
                )
            }

            return TrackSampleTable(
                track: track,
                maximumSize: maximumSize,
                durationUs: durationUs,
                samples: samples
            )
        }

        // See the BMFF spec (ISO/IEC 14496-12) subsection 8.6.6. Edit lists that require prerolling
        // from a sync sample after reordering are not supported. Partial audio sample truncation is
        // only supported in edit lists with one edit that removes less than
        // maxGaplessTrimSizeSamples samples from the start/end of the track. This implementation
        // handles simple discarding/delaying of samples. The extractor may place further restrictions
        // on what edited streams are playable.

        if editListDurations.count == 1, track.type == .audio, timestamps.count >= 2 {
            let editStartTime = editListMediaTimes[0]
            let editEndTime = editStartTime + Util.scaleLargeTimestamp(editListDurations[0],
                                                                       multiplier: track.timescale,
                                                                       divisor: track.movieTimescale)

            if canApplyEditWithGaplessInfo(timestamps: timestamps,
                                           duration: duration,
                                           editStartTime: editStartTime,
                                           editEndTime: editEndTime) {
                let paddingTimeUnits = duration - editEndTime
                let encoderDelay = Util.scaleLargeTimestamp(
                    editStartTime - timestamps[0],
                    multiplier: Int64(track.format2.sampleRate),
                    divisor: track.timescale
                )

                let encoderPadding = Util.scaleLargeTimestamp(
                    paddingTimeUnits,
                    multiplier: Int64(track.format2.sampleRate),
                    divisor: track.timescale
                )

                if (encoderDelay != 0 || encoderPadding != 0),
                   encoderDelay <= .max, encoderPadding <= .max {
                    gaplessInfoHolder = .init(
                        encoderDelay: Int(encoderDelay),
                        encoderPadding: Int(encoderDelay)
                    )

                    let samples = timestamps.enumerated().map { index, timestamp in
                        TrackSampleTable.Sample(
                            offset: offsets[index],
                            size: sizes[index],
                            presentationTimeStampUs: Util.scaleLargeTimestamp(
                                timestamp,
                                multiplier: Int64.microsecondsPerSecond,
                                divisor: track.timescale
                            ),
                            flags: samplesFlags[index]
                        )
                    }
                    let editedDurationUs = Util.scaleLargeTimestamp(
                        editListDurations[0],
                        multiplier: .microsecondsPerSecond,
                        divisor: track.movieTimescale
                    )

                    return TrackSampleTable(
                        track: track,
                        maximumSize: maximumSize,
                        durationUs: editedDurationUs,
                        samples: samples
                    )
                }
            }
        }

        if editListDurations.count == 1, editListDurations[0] == 0 {
            // The current version of the spec leaves handling of an edit with zero segment_duration in
            // unfragmented files open to interpretation. We handle this as a special case and include all
            // samples in the edit.
            let editStartTime = editListMediaTimes[0]
            let samples = timestamps.enumerated().map { index, timestamp in
                TrackSampleTable.Sample(
                    offset: offsets[index],
                    size: sizes[index],
                    presentationTimeStampUs: Util.scaleLargeTimestamp(
                        timestamp - editStartTime,
                        multiplier: Int64.microsecondsPerSecond,
                        divisor: track.timescale
                    ),
                    flags: samplesFlags[index]
                )
            }
            let editedDurationUs = Util.scaleLargeTimestamp(
                duration - editStartTime,
                multiplier: .microsecondsPerSecond,
                divisor: track.movieTimescale
            )

            return TrackSampleTable(
                track: track,
                maximumSize: maximumSize,
                durationUs: editedDurationUs,
                samples: samples
            )
        }

        // When applying edit lists, we need to include any partial clipped samples at the end to ensure
        // the final output is rendered correctly.
        // For audio only, we can omit any sample that starts at exactly the end point of an edit as
        // there is no partial audio in this case.
        let omitZeroDurationClippedSample = track.type == .audio

        // Count the number of samples after applying edits.
        var editedSampleCount = 0
        var nextSampleIndex = 0
        var copyMetadata = false
        var startIndices = Array(repeating: 0, count: editListDurations.count)
        var endIndices = Array(repeating: 0, count: editListDurations.count)

        for (index, (editMediaTime, editListDuration)) in zip(editListMediaTimes, editListDurations).enumerated() {
            guard editMediaTime != 1 else { continue }
            let editDuration = Util.scaleLargeTimestamp(editListDuration,
                                                        multiplier: track.timescale,
                                                        divisor: track.movieTimescale)
            // The timestamps array is in the order read from the media, which might not be strictly
            // sorted. However, all sync frames are guaranteed to be in order, and any out-of-order
            // frames appear after their respective sync frames. This ensures that although the result
            // of the binary search might not be entirely accurate (due to the out-of-order timestamps),
            // the following logic ensures correctness for both start and end indices.

            // The startIndices calculation finds the largest timestamp that is less than or equal to
            // editMediaTime. It then walks backward to ensure the index points to a sync frame, since
            // decoding must start from a keyframe. If a sync frame is not found by walking backward, it
            // walks forward from the initially found index to find a sync frame.
            startIndices[index] = Util.binarySearch(
                array: timestamps,
                value: editMediaTime,
                inclusive: true,
                stayInBounds: true
            )

            // The endIndices calculation finds the smallest timestamp that is greater than
            // editMediaTime + editDuration, except when omitZeroDurationClippedSample is true, in which
            // case it finds the smallest timestamp that is greater than or equal to editMediaTime +
            // editDuration.
            endIndices[index] = Util.binarySearchCeil(
                array: timestamps,
                value: editMediaTime + editDuration,
                inclusive: omitZeroDurationClippedSample,
                stayInBounds: false
            )

            let initialStartIndex = startIndices[index]
            while startIndices[index] >= 0,
                  !samplesFlags[startIndices[index]].contains(.keyframe) {
                startIndices[index] -= 1
            }

            if startIndices[index] < 0 {
                startIndices[index] = initialStartIndex
                while startIndices[index] < endIndices[index],
                      !samplesFlags[startIndices[index]].contains(.keyframe) {
                    startIndices[index] += 1
                }
            }

            if track.type == .video, startIndices[index] != endIndices[index] {
                // To account for out-of-order video frames that may have timestamps smaller than or equal
                // to editMediaTime + editDuration, but still fall within the valid range, the loop walks
                // forward through the timestamps array to ensure all frames with timestamps within the
                // edit duration are included.
                while endIndices[index] < timestamps.count - 1,
                      timestamps[endIndices[index] + 1] <= (editMediaTime + editDuration) {
                    endIndices[index] -= 1
                }
            }

            editedSampleCount += endIndices[index] - startIndices[index]
            copyMetadata = copyMetadata || (nextSampleIndex != startIndices[index])
            nextSampleIndex = endIndices[index]
        }
        copyMetadata = copyMetadata || editedSampleCount != sampleCount

        // Calculate edited sample timestamps and update the corresponding metadata arrays.
        var editedOffsets = copyMetadata ? Array(repeating: 0, count: editedSampleCount) : offsets
        var editedSizes = copyMetadata ? Array(repeating: 0, count: editedSampleCount) : sizes
        var editedMaximumSize = copyMetadata ? 0 : maximumSize
        var editedFlags = copyMetadata ? Array(repeating: [], count: editedSampleCount) : samplesFlags
        var editedTimestamps = copyMetadata ? Array(repeating: 0, count: editedSampleCount) : timestamps
        var pts = Int64.zero
        var sampleIndex = 0
        var hasPrerollSamples = false

        for (index, editMediaTime) in editListMediaTimes.enumerated() {
            let startIndex = startIndices[index]
            let endIndex = endIndices[index]
            if copyMetadata {
                let count = endIndex - startIndex
                editedOffsets.replaceSubrange(sampleIndex ..< sampleIndex + count,
                                              with: offsets[startIndex ..< endIndex])
                editedSizes.replaceSubrange(sampleIndex ..< sampleIndex + count,
                                            with: sizes[startIndex ..< endIndex])
                editedFlags.replaceSubrange(sampleIndex ..< sampleIndex + count,
                                            with: samplesFlags[startIndex ..< endIndex])
            }

            for j in startIndex..<endIndex {
                let ptsUs = Util.scaleLargeTimestamp(pts, multiplier: .microsecondsPerSecond, divisor: track.movieTimescale)
                let timeInSegmentUs = Util.scaleLargeTimestamp(
                    timestamps[j] - editMediaTime,
                    multiplier: .microsecondsPerSecond,
                    divisor: track.timescale
                )
                if timeInSegmentUs < 0 { hasPrerollSamples = true }
                editedTimestamps[sampleIndex] = ptsUs + timeInSegmentUs
                if copyMetadata, editedSizes[sampleIndex] > editedMaximumSize {
                    editedMaximumSize = sizes[j]
                }
                sampleIndex += 1
            }
            pts += editListDurations[index]
        }

        let editedDurationUs = Util.scaleLargeTimestamp(pts, multiplier: .microsecondsPerSecond, divisor: track.movieTimescale)
        if hasPrerollSamples {
            let newFormat = track.format2.buildUpon().setHasPrerollSamples(true).build()
            track.format2 = newFormat
        }

        let editedSamples = editedOffsets.enumerated().map { index, _ in
            TrackSampleTable.Sample(
                offset: editedOffsets[index],
                size: editedSizes[index],
                presentationTimeStampUs: editedTimestamps[index],
                flags: editedFlags[index]
            )
        }

        return TrackSampleTable(
            track: track,
            maximumSize: editedMaximumSize,
            durationUs: editedDurationUs,
            samples: editedSamples
        )
    }

    private func canApplyEditWithGaplessInfo(
        timestamps: [Int64],
        duration: Int64,
        editStartTime: Int64,
        editEndTime: Int64
    ) -> Bool {
        let lastIndex = timestamps.count - 1
        let latestDelayIndex = max(0, min(.maxGaplessTrimSizeSamples, lastIndex))
        let earliestPaddingIndex = max(0, min(timestamps.count - .maxGaplessTrimSizeSamples, lastIndex))

        return timestamps[0] <= editEndTime
            && editStartTime < timestamps[latestDelayIndex]
            && timestamps[earliestPaddingIndex] < editEndTime
            && editEndTime <= duration
    }

    struct TrackSampleTable {
        let track: Track
        let sampleCount: Int
        let maximumSize: Int
        let durationUs: Int64
        let samples: [Sample]

        struct Sample {
            let offset: Int
            let size: Int
            let presentationTimeStampUs: Int64
            let flags: SampleFlags
        }

        init(track: Track, maximumSize: Int, durationUs: Int64, samples: [Sample]) {
            self.track = track
            self.sampleCount = samples.count
            self.maximumSize = maximumSize
            self.durationUs = durationUs
            var samples = samples
            if !samples.isEmpty {
                let updatedSample = samples[samples.count - 1]
                samples[samples.count - 1] = Sample(
                    offset: updatedSample.offset,
                    size: updatedSample.size,
                    presentationTimeStampUs: updatedSample.presentationTimeStampUs,
                    flags: [updatedSample.flags, .lastSample]
                )
            }
            self.samples = samples
        }
    }
}

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

private extension BoxParser {
    struct ChunkIterator {
        var index = -1
        var offset = 0
        var numberOfSamples = 0

        private var stsc: ByteBuffer
        private var chunkOffsets: ByteBuffer
        private let chunkOffsetsType: any FixedWidthInteger.Type
        private let length: Int

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
