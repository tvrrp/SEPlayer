//
//  H265Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous H.265 byte stream and extracts individual frames.
final class H265Reader: ElementaryStreamReader {
    private let seiReader: SeiReader
    private let containerMimeType: MimeTypes
    private let allocator: CFAllocator

    private let vps: NalUnitTargetBuffer
    private let sps: NalUnitTargetBuffer
    private let pps: NalUnitTargetBuffer
    private let prefixSei: NalUnitTargetBuffer
    private let suffixSei: NalUnitTargetBuffer
    private let accumulator: NalUnitAccumulator

    private var formatId: String?
    private var output: TrackOutput?
    private var sampleReader: SampleReader?
    private var hasOutputFormat = false
    private var prefixFlags: (Bool, Bool, Bool) = (false, false, false)
    private var totalBytesWritten = 0
    private var pesTime = CMTime.invalid
    private var pesDecodeTime = CMTime.invalid

    init(seiReader: SeiReader, containerMimeType: MimeTypes, memoryPool: CMMemoryPool = CMMemoryPool()) throws {
        self.seiReader = seiReader
        self.containerMimeType = containerMimeType
        allocator = memoryPool.allocator
        vps = try NalUnitTargetBuffer(targetType: HevcUtil.videoParameterSetType, memoryPool: memoryPool)
        sps = try NalUnitTargetBuffer(targetType: HevcUtil.sequenceParameterSetType, memoryPool: memoryPool)
        pps = try NalUnitTargetBuffer(targetType: HevcUtil.pictureParameterSetType, memoryPool: memoryPool)
        prefixSei = try NalUnitTargetBuffer(targetType: HevcUtil.prefixSEIType, memoryPool: memoryPool)
        suffixSei = try NalUnitTargetBuffer(targetType: HevcUtil.suffixSEIType, memoryPool: memoryPool)
        accumulator = try NalUnitAccumulator(memoryPool: memoryPool, ignoreNalTypes: [])
    }

    func seek() {
        totalBytesWritten = 0
        pesTime = .invalid
        pesDecodeTime = .invalid
        prefixFlags = (false, false, false)
        vps.reset()
        sps.reset()
        pps.reset()
        prefixSei.reset()
        suffixSei.reset()
        seiReader.clear()
        // Partly accumulated units are cut by the discontinuity.
        accumulator.reset()
        sampleReader?.reset()
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .video)
        self.output = trackOutput
        sampleReader = SampleReader(trackOutput: trackOutput, accumulator: accumulator)
        try seiReader.createTracks(extractorOutput: output, idGenerator: idGenerator)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        self.pesTime = pesTime
        pesDecodeTime = decodeTime
    }

    func consume(data: inout BlockBufferReader) throws {
        try output.checkNotNil()
        guard data.readableBytes > 0 else { return }
        let view = data.readableBytesView
        var offset = view.startIndex
        let limit = view.endIndex
        // The readable bytes are consumed whatever happens.
        defer { data.moveReaderIndex(to: limit) }

        totalBytesWritten += view.count

        while true {
            // The scan reads the bytes in memory: through the view, every byte is a lookup in the block buffer.
            let (nalUnitOffset, nalUnitType, prefixSize) = try data.withUnsafeReadableBuffer { raw in
                let base = view.startIndex
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                var nalUnitOffset = NalUnitUtil.findNalUnit(
                    bytes,
                    offset: offset - base,
                    limit: limit - base,
                    prefixFlags: &prefixFlags
                )
                guard nalUnitOffset < limit - base else { return (limit, 0, 0) }
                let nalUnitType = Int((bytes[nalUnitOffset + 3] & 0x7E) >> 1)
                // A four-byte start code: the zero before the three-byte one isn't part of the previous unit.
                var prefixSize = 3
                if nalUnitOffset > 0, bytes[nalUnitOffset - 1] == 0x00 {
                    nalUnitOffset -= 1
                    prefixSize = 4
                }
                return (base + nalUnitOffset, nalUnitType, prefixSize)
            }

            if nalUnitOffset == limit {
                try nalUnitData(view, from: offset, to: limit)
                return
            }

            // Negative if the unit started in the data consumed before.
            let lengthToNalUnit = nalUnitOffset - offset
            if lengthToNalUnit > 0 {
                try nalUnitData(view, from: offset, to: nalUnitOffset)
            }

            let bytesWrittenPastPosition = limit - nalUnitOffset
            let absolutePosition = totalBytesWritten - bytesWrittenPastPosition
            // Bytes written to the unit that ended that belong to the start code of the next one are dropped.
            try endNalUnit(position: absolutePosition, discardPadding: lengthToNalUnit < 0 ? -lengthToNalUnit : 0)
            try startNalUnit(position: absolutePosition, nalUnitType: nalUnitType)
            offset = nalUnitOffset + prefixSize
        }
    }

    func endOfInputReached() throws {
        try output.checkNotNil()
        try seiReader.flush()
        try seiReader.writePendingSamples()
        try endNalUnit(position: totalBytesWritten, discardPadding: 0)
        try startNalUnit(position: totalBytesWritten, nalUnitType: HevcUtil.unspecifiedType)
        try sampleReader?.flush()
    }

    private func startNalUnit(position: Int, nalUnitType: Int) throws {
        guard let sampleReader else { return }
        try sampleReader.startNalUnit(
            position: position,
            type: nalUnitType,
            time: pesTime,
            decodeTime: pesDecodeTime,
            hasOutputFormat: hasOutputFormat
        )
        if !hasOutputFormat {
            vps.startNalUnit(type: nalUnitType)
            sps.startNalUnit(type: nalUnitType)
            pps.startNalUnit(type: nalUnitType)
        }
        prefixSei.startNalUnit(type: nalUnitType)
        suffixSei.startNalUnit(type: nalUnitType)
        try accumulator.startNalUnit(type: nalUnitType)
    }

    private func nalUnitData(_ data: BlockBufferView, from offset: Int, to limit: Int) throws {
        let slice = data[offset ..< limit]
        sampleReader?.readNalUnitData(slice)
        if !hasOutputFormat {
            try vps.appendToNalUnit(slice)
            try sps.appendToNalUnit(slice)
            try pps.appendToNalUnit(slice)
        }
        try prefixSei.appendToNalUnit(slice)
        try suffixSei.appendToNalUnit(slice)
        try accumulator.append(slice)
    }

    private func endNalUnit(position: Int, discardPadding: Int) throws {
        guard let sampleReader, let output else { return }
        try accumulator.finishNalUnit(discardPadding: discardPadding)
        try sampleReader.endNalUnit(hasOutputFormat: hasOutputFormat)

        if !hasOutputFormat {
            vps.endNalUnit(discardPadding: discardPadding)
            sps.endNalUnit(discardPadding: discardPadding)
            pps.endNalUnit(discardPadding: discardPadding)
            if vps.isCompleted, sps.isCompleted, pps.isCompleted {
                let format = try makeFormat()
                try output.setFormat(AnyFormat(format))
                try seiReader.setReorderingQueueSize(format.maxReorderFrames ?? 0)
                hasOutputFormat = true
            }
        }

        for sei in [prefixSei, suffixSei] where sei.endNalUnit(discardPadding: discardPadding) {
            let unescaped = try NalUnitUtil.unescapeStream(sei.nalBuffer, length: sei.nalLength, allocator: allocator)
            var seiBuffer = BlockBufferReader(unescaped)
            // The start code and the two-byte NAL unit header.
            seiBuffer.moveReaderIndex(to: 5)
            try seiReader.consume(pesTime: pesTime, seiBuffer: &seiBuffer)
            try seiReader.writePendingSamples()
        }
    }

    private func makeFormat() throws -> VideoFormat {
        // The parameter sets go in without the start code, with emulation prevention bytes.
        let parameterSets = [vps, sps, pps].map { buffer in
            BlockBufferReader(buffer.nalBuffer).bytesView[3 ..< buffer.nalLength]
        }
        // The whole unit, after the start code.
        let spsUnit = try BlockBufferReader(sps.nalBuffer).getSlice(at: 3, length: sps.nalLength - 3)
        let spsData = try HevcUtil.SequenceParameterSet(nalUnit: spsUnit)
        let record = HevcUtil.configurationRecord(
            videoParameterSets: [parameterSets[0]],
            sequenceParameterSets: [parameterSets[1]],
            pictureParameterSets: [parameterSets[2]],
            sequenceParameterSet: spsData
        )

        var format = try VideoFormat(
            codecType: kCMVideoCodecType_HEVC,
            width: spsData.width,
            height: spsData.height,
            configurationRecord: record,
            flavor: .h265
        )
        format.id = try formatId.checkNotNil()
        format.containerMimeType = containerMimeType
        format.codecs = spsData.profileTierLevel.codecs(sampleEntryType: .hvc1)
        format.maxReorderFrames = spsData.maxNumReorderPics
        return format
    }
}

private extension H265Reader {
    /// Finds where samples start and end, and writes them.
    final class SampleReader {
        private let delayedOutput: DelayedSampleOutput
        private let accumulator: NalUnitAccumulator

        private var nalUnitPosition = 0
        private var nalUnitHasKeyframeData = false
        private var nalUnitBytesRead = 0
        private var nalUnitTime = CMTime.invalid
        private var nalUnitDecodeTime = CMTime.invalid
        private var lookingForFirstSliceFlag = false
        private var isFirstSlice = false
        private var isFirstPrefixNalUnit = false
        private var readingSample = false
        private var readingPrefix = false
        private var samplePosition = 0
        private var sampleTime = CMTime.invalid
        private var sampleDecodeTime = CMTime.invalid
        private var sampleIsKeyframe = false

        init(trackOutput: TrackOutput, accumulator: NalUnitAccumulator) {
            delayedOutput = DelayedSampleOutput(trackOutput: trackOutput)
            self.accumulator = accumulator
        }

        func reset() {
            lookingForFirstSliceFlag = false
            isFirstSlice = false
            isFirstPrefixNalUnit = false
            readingSample = false
            readingPrefix = false
            delayedOutput.reset()
        }

        func flush() throws {
            try delayedOutput.flush()
        }

        /// Called before the unit is accumulated: a sample that ends here doesn't have it.
        func startNalUnit(position: Int, type: Int, time: CMTime, decodeTime: CMTime, hasOutputFormat: Bool) throws {
            isFirstSlice = false
            isFirstPrefixNalUnit = false
            nalUnitTime = time
            nalUnitDecodeTime = decodeTime
            nalUnitBytesRead = 0
            nalUnitPosition = position

            if !Self.isVclBodyNalUnit(type) {
                if readingSample, !readingPrefix {
                    let data = try accumulator.commit()
                    if hasOutputFormat, let data {
                        try outputSample(data)
                    }
                    readingSample = false
                }
                if Self.isPrefixNalUnit(type) {
                    isFirstPrefixNalUnit = !readingPrefix
                    readingPrefix = true
                }
            }
            nalUnitHasKeyframeData = (HevcUtil.firstRandomAccessPointType ... HevcUtil.lastRandomAccessPointType).contains(type)
            lookingForFirstSliceFlag = nalUnitHasKeyframeData || type <= HevcUtil.lastTrailingOrLeadingSliceType
        }

        /// Reads first_slice_segment_in_pic_flag, the first bit after the two-byte NAL unit header.
        func readNalUnitData(_ data: BlockBufferView) {
            guard lookingForFirstSliceFlag else { return }
            let headerOffset = Self.firstSliceFlagOffset - nalUnitBytesRead
            if headerOffset < data.count {
                isFirstSlice = data[data.startIndex + headerOffset] & 0x80 != 0
                lookingForFirstSliceFlag = false
            } else {
                nalUnitBytesRead += data.count
            }
        }

        /// Called after the unit is accumulated: a sample that ends here doesn't have it.
        func endNalUnit(hasOutputFormat: Bool) throws {
            if readingPrefix, isFirstSlice {
                // The prefix units before the first slice belong to its sample.
                sampleIsKeyframe = nalUnitHasKeyframeData
                readingPrefix = false
            } else if isFirstPrefixNalUnit || isFirstSlice {
                if readingSample {
                    let data = try accumulator.commitExcludingLastUnit()
                    if hasOutputFormat, let data {
                        try outputSample(data)
                    }
                } else {
                    // Units before the first sample can't be decoded.
                    _ = try accumulator.commitExcludingLastUnit()
                }
                samplePosition = nalUnitPosition
                sampleTime = nalUnitTime
                sampleDecodeTime = nalUnitDecodeTime
                sampleIsKeyframe = nalUnitHasKeyframeData
                readingSample = true
            }
        }

        private func outputSample(_ data: CMBlockBuffer) throws {
            guard sampleTime.isNumeric, nalUnitPosition != samplePosition else { return }
            try delayedOutput.output(
                data: data,
                time: sampleTime,
                decodeTime: sampleDecodeTime,
                flags: sampleIsKeyframe ? .keyframe : []
            )
        }

        private static let firstSliceFlagOffset = 2

        private static func isPrefixNalUnit(_ type: Int) -> Bool {
            (HevcUtil.videoParameterSetType ... HevcUtil.accessUnitDelimiterType).contains(type) || type == HevcUtil.prefixSEIType
        }

        private static func isVclBodyNalUnit(_ type: Int) -> Bool {
            type < HevcUtil.videoParameterSetType || type == HevcUtil.suffixSEIType
        }
    }
}
