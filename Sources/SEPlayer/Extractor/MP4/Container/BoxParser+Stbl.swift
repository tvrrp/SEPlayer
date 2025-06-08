//
//  BoxParser+Stbl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMTime

extension BoxParser {
    func parseStbl(track: Track, stblBox: ContainerBox) throws -> TrackSampleTable {
        var sampleSizeBox: SampleSizeBox = if let stszAtom = stblBox.getLeafBoxOfType(type: .stsz) {
            try! StszSampleSizeBox(stszAtom: stszAtom)
        } else if let stz2Atom = stblBox.getLeafBoxOfType(type: .stz2) {
            try! Stz2SampleSizeBox(stszAtom: stz2Atom)
        } else {
            throw BoxParserErrors.badBoxContent(
                type: .stbl, reason: "Track has no sample table size information"
            )
        }

        let sampleCount = sampleSizeBox.sampleCount
        if sampleCount == 0 {
            return TrackSampleTable(track: track, maximumSize: 0, durationUs: .zero, samples: [])
        }

//        if case .video = track.type {
            // TODO: calc
//            let frameRate = Float(sampleCount / (track.duration))
//        }

        var chunkOffsetsType: any FixedWidthInteger.Type = UInt32.self
        let chunkOffsetsAtom: LeafBox
        if let stblBox = stblBox.getLeafBoxOfType(type: .stco) {
            chunkOffsetsAtom = stblBox
        } else {
            chunkOffsetsType = UInt64.self
            chunkOffsetsAtom = try! stblBox.getLeafBoxOfType(type: .co64)
                .checkNotNil(BoxParserErrors.missingBox(type: .stco))
        }

        let chunkOffsets = chunkOffsetsAtom.data
        let stsc = try! stblBox.getLeafBoxOfType(type: .stsc).checkNotNil(BoxParserErrors.missingBox(type: .stsc)).data
        var stts = try! stblBox.getLeafBoxOfType(type: .stts).checkNotNil(BoxParserErrors.missingBox(type: .stts)).data
        var stss = stblBox.getLeafBoxOfType(type: .stss)?.data
        var ctts = stblBox.getLeafBoxOfType(type: .ctts)?.data

        var chunkIterator = try! ChunkIterator(
            stsc: stsc, chunkOffsets: chunkOffsets, chunkOffsetsType: chunkOffsetsType
        )

        stts.moveReaderIndex(to: MP4Box.fullHeaderSize)
        var remainingTimestampDeltaChanges = try! stts.readInt(as: UInt32.self) - 1
        var remainingSamplesAtTimestampDelta = try! stts.readInt(as: UInt32.self)
        var timestampDeltaInTimeUnits = try! CMTimeValue(stts.readInt(as: UInt32.self))
        
        var remainingSamplesAtTimestampOffset: UInt32 = 0
        var remainingTimestampOffsetChanges: UInt32 = 0
        var timestampOffset: CMTimeValue = 0
        try! ctts.withTransform { ctts in
            ctts.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingTimestampOffsetChanges = try! ctts.readInt(as: UInt32.self)
        }

        var nextSynchronizationSampleIndex: Int?
        var remainingSynchronizationSamples: UInt32 = 1

        if var stssBox = stss {
            stssBox.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingSynchronizationSamples = try! stssBox.readInt(as: UInt32.self)
            if remainingSynchronizationSamples > 0 {
                nextSynchronizationSampleIndex = try! Int(stssBox.readInt(as: UInt32.self)) - 1
                stss = stssBox
            } else {
                // Ignore empty stss boxes, which causes all samples to be treated as sync samples.
                stss = nil
            }
        }

        var maximumSize = 0
        var timestampTimeUnits: Int64 = 0
        var samples = [TrackSampleTable.Sample]()
        var durationUs: Int64 = 0

        var offset = 0
        var remainingSamplesInChunk = 0

        for index in 0..<sampleCount {
            while remainingSamplesInChunk == 0, try! chunkIterator.moveNext() {
                offset = chunkIterator.offset
                remainingSamplesInChunk = chunkIterator.numberOfSamples
            }

            try! ctts.withTransform { ctts in
                while remainingSamplesAtTimestampOffset == 0 && remainingTimestampOffsetChanges > 0 {
                    remainingSamplesAtTimestampOffset = try! ctts.readInt(as: UInt32.self)
                    // The BMFF spec (ISO/IEC 14496-12) states that sample offsets should be unsigned
                    // integers in version 0 ctts boxes, however some streams violate the spec and use
                    // signed integers instead. It's safe to always decode sample offsets as signed integers
                    // here, because unsigned integers will still be parsed correctly (unless their top bit
                    // is set, which is never true in practice because sample offsets are always small).
                    timestampOffset = try! CMTimeValue(ctts.readInt(as: Int32.self))
                    remainingTimestampOffsetChanges -= 1
                }
                remainingSamplesAtTimestampOffset -= 1
            }

            let size = try! sampleSizeBox.readNextSampleSize()
            if size > maximumSize {
                maximumSize = size
            }

            var flags: SampleFlags = [stss == nil ? .keyframe : []]
            if index == nextSynchronizationSampleIndex {
                flags = [.keyframe]
                remainingSynchronizationSamples -= 1
                if remainingSynchronizationSamples > 0 {
                    var stssBox = try! stss.checkNotNil(BoxParserErrors.missingBox(type: .stss))
                    nextSynchronizationSampleIndex = try! Int(stssBox.readInt(as: UInt32.self)) - 1
                    stss = stssBox
                }
            }

            samples.append(.init(
                offset: offset,
                size: size,
                presentationTimeStampUs: Util.scaleLargeTimestamp(
                    timestampTimeUnits + timestampOffset,
                    multiplier: Int64.microsecondsPerSecond,
                    divisor: track.timescale
                ),
                flags: flags
            ))

            // Add on the duration of this sample.
            timestampTimeUnits += timestampDeltaInTimeUnits
            remainingSamplesAtTimestampDelta -= 1
            if remainingSamplesAtTimestampDelta == 0 && remainingTimestampDeltaChanges > 0 {
                remainingSamplesAtTimestampDelta = try! stts.readInt(as: UInt32.self)
                // The BMFF spec (ISO/IEC 14496-12) states that sample deltas should be unsigned integers
                // in stts boxes, however some streams violate the spec and use signed integers instead.
                // It's safe to always decode sample deltas as signed integers here,
                // because unsigned integers will still be parsed correctly
                // (unless their top bit is set, which is never true in practice because sample
                // deltas are always small).
                timestampDeltaInTimeUnits = try! CMTimeValue(stts.readInt(as: Int32.self))
                remainingTimestampDeltaChanges -= 1
            }

            offset += size
            remainingSamplesInChunk -= 1
        }
        durationUs = timestampTimeUnits + timestampOffset

        var isCttsValid = true
        try! ctts.withTransform { ctts in
            while remainingTimestampOffsetChanges > 0 {
                if try! ctts.readInt(as: UInt32.self) > 0 {
                    isCttsValid = false
                    break
                }
                try! ctts.readInt(as: Int32.self)
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

        return TrackSampleTable(
            track: track,
            maximumSize: maximumSize,
            durationUs: Util.scaleLargeTimestamp(
                durationUs,
                multiplier: Int64.microsecondsPerSecond,
                divisor: track.timescale
            ),
            samples: samples
        )
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
                    flags: [updatedSample.flags, .endOfStream]
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
            let sampleSize = try! data.readInt(as: UInt32.self)
            fixedSampleSize = sampleSize == 0 ? nil : Int(sampleSize)
            sampleCount = try! Int(data.readInt(as: UInt32.self))
        }
        
        mutating func readNextSampleSize() throws -> Int {
            if let fixedSampleSize {
                return fixedSampleSize
            } else {
                return try! Int(data.readInt(as: UInt32.self))
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
            fieldSize = try! Int(data.readInt(as: UInt32.self)) & 0x000000FF
            sampleCount = try! Int(data.readInt(as: UInt32.self))
        }

        mutating func readNextSampleSize() throws -> Int {
            if fieldSize == 8 {
                return try! Int(data.readInt(as: UInt8.self))
            } else if fieldSize == 16 {
                return try! Int(data.readInt(as: UInt16.self))
            } else { // fieldSize == 4.
                sampleIndex += 1
                if sampleIndex % 2 == 0 {
                    // Read the next byte into our cached byte when we are reading the upper bits.
                    currentByte = try! Int(data.readInt(as: UInt8.self))
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
            length = try! Int(self.chunkOffsets.readInt(as: UInt32.self))
            self.stsc.moveReaderIndex(to: MP4Box.fullHeaderSize)
            remainingSamplesPerChunkChanges = try! Int(self.stsc.readInt(as: UInt32.self))
            guard try! self.stsc.readInt(as: UInt32.self) == 1 else {
                throw BoxParserErrors.badBoxContent(type: .stsc, reason: "first_chunk must be 1")
            }
        }

        mutating func moveNext() throws -> Bool {
            index += 1
            if index == length {
                return false
            }

            offset = try! Int(chunkOffsets.readInt(as: chunkOffsetsType))
            if index == nextSamplesPerChunkChangeIndex {
                numberOfSamples = try! Int(stsc.readInt(as: UInt32.self))
                stsc.moveReaderIndex(forwardBy: 4) // Skip sample_description_index
                remainingSamplesPerChunkChanges -= 1
                nextSamplesPerChunkChangeIndex = if remainingSamplesPerChunkChanges > 0 {
                    try! Int(stsc.readInt(as: UInt32.self) - 1)
                } else {
                    nil
                }
            }
            return true
        }
    }
}
