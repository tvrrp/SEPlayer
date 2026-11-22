//
//  H264Reader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.H264Reader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous H264 byte stream and extracts individual frames.
final class H264Reader: ElementaryStreamReader {
    private let seiReader: SeiReader
    private let allowNonIdrKeyframes: Bool
    private let detectAccessUnits: Bool
    private let containerMimeType: MimeTypes

    private let sps: NalUnitTargetBuffer
    private let pps: NalUnitTargetBuffer
    private let sei: NalUnitTargetBuffer
    private let accumulator: NalUnitAccumulator
    private let allocator: CFAllocator

    private var totalBytesWritten = 0
    private var prefixFlags: (Bool, Bool, Bool) = (false, false, false)

    private var formatId: String?
    private var output: TrackOutput?
    private var sampleReader: SampleReader?

    /// State that should not be reset on seek.
    private var hasOutputFormat = false

    // Per PES packet state that gets reset at the start of each PES packet.
    private var pesTime: CMTime = .invalid
    private var pesDecodeTime: CMTime = .invalid

    /// State inherited from the TS packet header.
    private var randomAccessIndicator = false

    private var seiWrapper: BlockBufferReader

    init(
        seiReader: SeiReader,
        allowNonIdrKeyframes: Bool,
        detectAccessUnits: Bool,
        containerMimeType: MimeTypes,
        memoryPool: CMMemoryPool = CMMemoryPool()
    ) throws {
        self.seiReader = seiReader
        self.allowNonIdrKeyframes = allowNonIdrKeyframes
        self.detectAccessUnits = detectAccessUnits
        self.containerMimeType = containerMimeType
        self.allocator = memoryPool.allocator
        self.sps = try NalUnitTargetBuffer(targetType: NalUnitUtil.H264NalUnitType.sps, memoryPool: memoryPool)
        self.pps = try NalUnitTargetBuffer(targetType: NalUnitUtil.H264NalUnitType.pps, memoryPool: memoryPool)
        self.sei = try NalUnitTargetBuffer(targetType: NalUnitUtil.H264NalUnitType.sei, memoryPool: memoryPool)
        self.accumulator = try NalUnitAccumulator(
            memoryPool: memoryPool,
            ignoreNalTypes: [
//                NalUnitUtil.H264NalUnitType.sps.rawValue,
//                NalUnitUtil.H264NalUnitType.pps.rawValue,
//                NalUnitUtil.H264NalUnitType.sei.rawValue,
            ]
        )
        seiWrapper = try BlockBufferReader()
    }

    func seek() {
        totalBytesWritten = 0
        randomAccessIndicator = false
        pesTime = .invalid
        pesDecodeTime = .invalid
        prefixFlags = (false, false, false)
        sps.reset()
        pps.reset()
        sei.reset()
        seiReader.clear()
        // Partially accumulated NAL units are truncated by the discontinuity, so drop them instead
        // of gluing them onto the first sample that follows.
        accumulator.reset()
        sampleReader?.reset()
    }

    func createTracks(
        output: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .video)
        self.output = trackOutput
        sampleReader = try SampleReader(
            trackOutput: trackOutput,
            allowNonIdrKeyframes: allowNonIdrKeyframes,
            detectAccessUnits: detectAccessUnits,
            accumulator: accumulator
        )
        try seiReader.createTracks(
            extractorOutput: output,
            idGenerator: idGenerator
        )
    }

    func packetStarted(
        pesTime: CMTime,
        decodeTime: CMTime,
        flags: TsPayload.PacketIndicators
    ) {
        self.pesTime = pesTime
        self.pesDecodeTime = decodeTime
        if flags.contains(.randomAccess) {
            randomAccessIndicator = true
        }
    }

    func consume(data: inout BlockBufferReader) throws {
        try checkTracksCreated()
        guard data.readableBytes > 0 else { return }
        let view = data.readableBytesView
        var offset = view.startIndex
        let limit = view.endIndex
        // The readable bytes are consumed whatever happens.
        defer { data.moveReaderIndex(to: limit) }

        totalBytesWritten += view.count

        // Scan the appended data, processing NAL units as they are encountered
        while true {
            // The scan reads the bytes in memory: through the view, every byte is a lookup in the block buffer.
            let (nalUnitOffset, nalUnitType, prefixSize) = try data.withUnsafeReadableBuffer { raw in
                // The memory starts at the view's start.
                let base = view.startIndex
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                var nalUnitOffset = NalUnitUtil.findNalUnit(
                    bytes,
                    offset: offset - base,
                    limit: limit - base,
                    prefixFlags: &prefixFlags
                )
                guard nalUnitOffset < limit - base else { return (limit, 0, 0) }
                // We've seen the start of a NAL unit of the following type.
                let nalUnitType = Int(bytes[nalUnitOffset + 3] & 0x1F)
                // Case of a 4 byte start code prefix 0x00000001, recoil NAL unit offset by one byte
                // to avoid previous byte being assigned to the previous access unit.
                var prefixSize = 3
                if nalUnitOffset > 0, bytes[nalUnitOffset - 1] == 0x00 {
                    nalUnitOffset -= 1
                    prefixSize = 4
                }
                return (base + nalUnitOffset, nalUnitType, prefixSize)
            }

            if nalUnitOffset == limit {
                // We've scanned to the end of the data without finding the start of another NAL unit.
                try nalUnitData(view, from: offset, to: limit)
                return
            }

            // This is the number of bytes from the current offset to the start of the next NAL unit.
            // It may be negative if the NAL unit started in the previously consumed data.
            let lengthToNalUnit = nalUnitOffset - offset
            if lengthToNalUnit > 0 {
                try nalUnitData(view, from: offset, to: nalUnitOffset)
            }

            let bytesWrittenPastPosition = limit - nalUnitOffset
            let absolutePosition = totalBytesWritten - bytesWrittenPastPosition
            // Indicate the end of the previous NAL unit. If the length to the start of the next unit
            // is negative then we wrote too many bytes to the NAL buffers. Discard the excess bytes
            // when notifying that the unit has ended.
            try endNalUnit(
                position: absolutePosition,
                offset: bytesWrittenPastPosition,
                discardPadding: lengthToNalUnit < 0 ? -lengthToNalUnit : 0,
                pesTime: pesTime
            )
            // Indicate the start of the next NAL unit.
            try startNalUnit(
                position: absolutePosition,
                nalUnitType: nalUnitType,
                pesTime: pesTime,
                pesDecodeTime: pesDecodeTime
            )
            // Continue scanning the data.
            offset = nalUnitOffset + prefixSize
        }
    }

    func endOfInputReached() throws {
        try checkTracksCreated()
        try seiReader.flush()
        try seiReader.writePendingSamples()
        // Simulate end of current NAL unit and start an AUD one to trigger output of current sample
        try endNalUnit(position: totalBytesWritten, offset: 0, discardPadding: 0, pesTime: pesTime)
        try startNalUnit(
            position: totalBytesWritten,
            nalUnitType: NalUnitUtil.H264NalUnitType.aud.rawValue,
            pesTime: pesTime,
            pesDecodeTime: pesDecodeTime
        )
        try endNalUnit(position: totalBytesWritten, offset: 0, discardPadding: 0, pesTime: pesTime)
        // No further sample will arrive to provide the last sample's duration, so release it now.
        try sampleReader?.flushPendingSample()
    }

    private func startNalUnit(
        position: Int,
        nalUnitType: Int,
        pesTime: CMTime,
        pesDecodeTime: CMTime
    ) throws {
        guard let sampleReader else { return }
        if !hasOutputFormat || sampleReader.needsSpsPps() {
            sps.startNalUnit(type: nalUnitType)
            pps.startNalUnit(type: nalUnitType)
        }
        sei.startNalUnit(type: nalUnitType)
        try accumulator.startNalUnit(type: nalUnitType)
        try sampleReader.startNalUnit(
            position: position,
            type: nalUnitType,
            pesTime: pesTime,
            decodeTime: pesDecodeTime,
            randomAccessIndicator: randomAccessIndicator
        )
    }

    private func nalUnitData(
        _ data: BlockBufferView,
        from offset: Int,
        to limit: Int
    ) throws {
        guard let sampleReader else { return }

        let slice = data[offset ..< limit]
        if !hasOutputFormat || sampleReader.needsSpsPps() {
            try sps.appendToNalUnit(slice)
            try pps.appendToNalUnit(slice)
        }
        try accumulator.append(slice)
        try sei.appendToNalUnit(slice)
        try sampleReader.appendToNalUnit(slice)
    }

    private func endNalUnit(
        position: Int,
        offset: Int,
        discardPadding: Int,
        pesTime: CMTime
    ) throws {
        guard let sampleReader, let output, let formatId else { return }
        if !hasOutputFormat || sampleReader.needsSpsPps() {
            sps.endNalUnit(discardPadding: discardPadding)
            pps.endNalUnit(discardPadding: discardPadding)

            if !hasOutputFormat {
                if sps.isCompleted, pps.isCompleted {
                    let spsView = BlockBufferReader(sps.nalBuffer).bytesView
                    let ppsView = BlockBufferReader(pps.nalBuffer).bytesView
                    let spsData = try NalUnitUtil.parseSpsNalUnit(
                        nalData: spsView,
                        nalOffset: 3,
                        nalLimit: sps.nalLength
                    )
                    let ppsData = try NalUnitUtil.parsePpsNalUnit(
                        nalData: ppsView,
                        nalOffset: 3,
                        nalLimit: pps.nalLength
                    )
                    // The parameter sets go in without the start code and with emulation
                    // prevention bytes intact, so the 3-byte prefix is dropped here.
                    let record = AvcUtil.configurationRecord(
                        sequenceParameterSets: [spsView[3 ..< sps.nalLength]],
                        pictureParameterSets: [ppsView[3 ..< pps.nalLength]],
                        sequenceParameterSet: spsData
                    )
                    var format = try VideoFormat(
                        codecType: kCMVideoCodecType_H264,
                        width: spsData.width,
                        height: spsData.height,
                        configurationRecord: record,
                        flavor: .h264
                    )
                    format.id = formatId
                    format.containerMimeType = containerMimeType
                    format.codecs = format.codec?.h264.codecs()
                    format.maxReorderFrames = spsData.maxNumReorderFrames
                    try output.setFormat(AnyFormat(format))
                    hasOutputFormat = true
                    try seiReader.setReorderingQueueSize(spsData.maxNumReorderFrames)
                    sampleReader.putSps(spsData)
                    sampleReader.putPps(ppsData)
                    sps.reset()
                    pps.reset()
                }
            } else if sps.isCompleted {
                let spsData = try NalUnitUtil.parseSpsNalUnit(
                    nalData: BlockBufferReader(sps.nalBuffer).bytesView,
                    nalOffset: 3,
                    nalLimit: sps.nalLength
                )
                try seiReader.setReorderingQueueSize(spsData.maxNumReorderFrames)
                sampleReader.putSps(spsData)
                sps.reset()
            } else if pps.isCompleted {
                let ppsData = try NalUnitUtil.parsePpsNalUnit(
                    nalData: BlockBufferReader(pps.nalBuffer).bytesView,
                    nalOffset: 3,
                    nalLimit: pps.nalLength
                )
                sampleReader.putPps(ppsData)
                pps.reset()
            }
        }

        if sei.endNalUnit(discardPadding: discardPadding) {
            let unescaped = try NalUnitUtil.unescapeStream(
                sei.nalBuffer,
                length: sei.nalLength,
                allocator: allocator
            )
            var seiBuffer = BlockBufferReader(unescaped)
            // NAL prefix and nal_unit() header.
            seiBuffer.moveReaderIndex(to: 4)
            try seiReader.consume(pesTime: pesTime, seiBuffer: &seiBuffer)
            try seiReader.writePendingSamples()
        }

        try accumulator.finishNalUnit(discardPadding: discardPadding)
        let sampleIsKeyFrame = try sampleReader.endNalUnit(hasOutputFormat: hasOutputFormat)
        if sampleIsKeyFrame {
            // This is either an IDR frame or the first I-frame since the random access indicator, so mark
            // it as a keyframe. Clear the flag so that subsequent non-IDR I-frames are not marked as
            // keyframes until we see another random access indicator.
            randomAccessIndicator = false
        }
    }

    private func checkTracksCreated() throws {
        try output.checkNotNil()
        try sampleReader.checkNotNil()
    }
}

private final class SampleReader {
    /// Samples are written one behind, so that the duration of each comes from the time of the next.
    private let delayedOutput: DelayedSampleOutput
    private let allowNonIdrKeyframes: Bool
    private let detectAccessUnits: Bool
    private let accumulator: NalUnitAccumulator

    private var sps: [Int: NalUnitUtil.SpsData] = [:]
    private var pps: [Int: NalUnitUtil.PpsData] = [:]

    private var buffer: BlockBufferReader

    private var nalUnitType = NalUnitUtil.H264NalUnitType.unspecified
    private var nalUnitStartPosition = 0
    private var isFilling = false
    private var nalUnitTime: CMTime = .invalid
    private var nalUnitDecodeTime: CMTime = .invalid
    private var previousSliceHeader = SliceHeaderData()
    private var sliceHeader = SliceHeaderData()

    private var readingSample = false
    private var samplePosition = 0
    private var sampleTime: CMTime = .invalid
    private var sampleDecodeTime: CMTime = .invalid
    private var sampleIsKeyframe = false
    private var randomAccessIndicator = false
    private var currentOffset = 0

    init(
        trackOutput: TrackOutput,
        allowNonIdrKeyframes: Bool,
        detectAccessUnits: Bool,
        accumulator: NalUnitAccumulator
    ) throws {
        delayedOutput = DelayedSampleOutput(trackOutput: trackOutput)
        self.allowNonIdrKeyframes = allowNonIdrKeyframes
        self.detectAccessUnits = detectAccessUnits
        self.accumulator = accumulator
        buffer = try BlockBufferReader()
    }

    func needsSpsPps() -> Bool {
        detectAccessUnits
    }

    func putSps(_ spsData: NalUnitUtil.SpsData) {
        sps[spsData.seqParameterSetId] = spsData
    }

    func putPps(_ ppsData: NalUnitUtil.PpsData) {
        pps[ppsData.picParameterSetId] = ppsData
    }

    func reset() {
        isFilling = false
        readingSample = false
        sliceHeader.clear()
        // Called on a seek and on a transport stream discontinuity. The held back sample is dropped
        // rather than output: its data may be truncated by the packet loss, and the timestamps that
        // follow are not contiguous with it, so they cannot provide its duration.
        delayedOutput.reset()
    }

    func startNalUnit(
        position: Int,
        type: Int,
        pesTime: CMTime,
        decodeTime: CMTime,
        randomAccessIndicator: Bool
    ) throws {
        nalUnitType = .init(rawValue: type) ?? .unspecified
        nalUnitTime = pesTime
        nalUnitDecodeTime = decodeTime
        nalUnitStartPosition = position
        self.randomAccessIndicator = randomAccessIndicator

        if (allowNonIdrKeyframes && nalUnitType == NalUnitUtil.H264NalUnitType.nonIdr)
            || (detectAccessUnits
                && (nalUnitType == NalUnitUtil.H264NalUnitType.idr
                    || nalUnitType == NalUnitUtil.H264NalUnitType.nonIdr
                    || nalUnitType == NalUnitUtil.H264NalUnitType.partitionA)) {
            // Store the previous header and prepare to populate the new one.
            swap(&previousSliceHeader, &sliceHeader)
            sliceHeader.clear()
            try buffer.clear()
            isFilling = true
        }
    }

    /// Called to pass stream data. The data passed should not include the 3 byte start code.
    func appendToNalUnit(_ source: BlockBufferView) throws {
        guard isFilling, source.count > 0 else { return }
        try buffer.extend(with: source)

        var bitArray = try ParsableNalUnitBitArray(
            data: buffer.readableBytesView,
            offset: 0,
            limit: buffer.readableBytes
        )
        guard bitArray.canReadBits(8) else { return }
        try bitArray.skipBit()
        let nalRefIdc = try bitArray.readBits(2)
        try bitArray.skipBits(5)

        // Read the slice header using the syntax defined in ITU-T Recommendation H.264 (2013)
        // subsection 7.3.3.
        guard try bitArray.canReadExpGolombCodedNum() else { return }
        try bitArray.readUnsignedExpGolombCodedInt()
        guard try bitArray.canReadExpGolombCodedNum() else { return }
        let sliceType = try bitArray.readUnsignedExpGolombCodedInt()
        if !detectAccessUnits {
            // There are AUDs in the stream so the rest of the header can be ignored.
            isFilling = false
            sliceHeader.setSliceType(sliceType)
            return
        }
        guard try bitArray.canReadExpGolombCodedNum() else { return }
        let picParameterSetId = try bitArray.readUnsignedExpGolombCodedInt()
        guard let ppsData = pps[picParameterSetId] else {
            // We have not seen the PPS yet, so don't try to decode the slice header.
            isFilling = false
            return
        }
        guard let spsData = sps[ppsData.seqParameterSetId] else {
            isFilling = false
            return
        }
        if spsData.separateColorPlaneFlag {
            guard bitArray.canReadBits(2) else { return }
            try bitArray.skipBits(2)
        }
        guard bitArray.canReadBits(spsData.frameNumLength) else { return }

        var fieldPicFlag = false
        var bottomFieldFlagPresent = false
        var bottomFieldFlag = false
        let frameNum = try bitArray.readBits(spsData.frameNumLength)
        if !spsData.frameMbsOnlyFlag {
            guard bitArray.canReadBits(1) else { return }
            fieldPicFlag = try bitArray.readBit()
            if fieldPicFlag {
                guard bitArray.canReadBits(1) else { return }
                bottomFieldFlag = try bitArray.readBit()
                bottomFieldFlagPresent = true
            }
        }
        let idrPicFlag = nalUnitType == NalUnitUtil.H264NalUnitType.idr
        var idrPicId = 0
        if idrPicFlag {
            guard try bitArray.canReadExpGolombCodedNum() else { return }
            idrPicId = try bitArray.readUnsignedExpGolombCodedInt()
        }
        var picOrderCntLsb = 0
        var deltaPicOrderCntBottom = 0
        var deltaPicOrderCnt0 = 0
        var deltaPicOrderCnt1 = 0
        if spsData.picOrderCountType == 0 {
            guard bitArray.canReadBits(spsData.picOrderCntLsbLength) else {
                return
            }
            picOrderCntLsb = try bitArray.readBits(spsData.picOrderCntLsbLength)
            if ppsData.bottomFieldPicOrderInFramePresentFlag, !fieldPicFlag {
                guard try bitArray.canReadExpGolombCodedNum() else { return }
                deltaPicOrderCntBottom = try bitArray.readSignedExpGolombCodedInt()
            }
        } else if spsData.picOrderCountType == 1, !spsData.deltaPicOrderAlwaysZeroFlag {
            guard try bitArray.canReadExpGolombCodedNum() else { return }
            deltaPicOrderCnt0 = try bitArray.readSignedExpGolombCodedInt()
            if ppsData.bottomFieldPicOrderInFramePresentFlag, !fieldPicFlag {
                guard try bitArray.canReadExpGolombCodedNum() else { return }
                deltaPicOrderCnt1 = try bitArray.readSignedExpGolombCodedInt()
            }
        }

        sliceHeader.setAll(
            spsData: spsData,
            nalRefIdc: nalRefIdc,
            sliceType: sliceType,
            frameNum: frameNum,
            picParameterSetId: picParameterSetId,
            fieldPicFlag: fieldPicFlag,
            bottomFieldFlagPresent: bottomFieldFlagPresent,
            bottomFieldFlag: bottomFieldFlag,
            idrPicFlag: idrPicFlag,
            idrPicId: idrPicId,
            picOrderCntLsb: picOrderCntLsb,
            deltaPicOrderCntBottom: deltaPicOrderCntBottom,
            deltaPicOrderCnt0: deltaPicOrderCnt0,
            deltaPicOrderCnt1: deltaPicOrderCnt1
        )
        isFilling = false
    }

    @discardableResult
    func endNalUnit(
        hasOutputFormat: Bool
    ) throws -> Bool {
        if nalUnitType == NalUnitUtil.H264NalUnitType.aud
            || (detectAccessUnits && sliceHeader.isFirstVclNalUnitOfPicture(previousSliceHeader)) {
            // If the NAL unit ending is the start of a new sample, output the previous one.
            if hasOutputFormat, readingSample {
                try completeSample()
            }
            samplePosition = nalUnitStartPosition
            sampleTime = nalUnitTime
            sampleDecodeTime = nalUnitDecodeTime
            sampleIsKeyframe = false
            readingSample = true
        }
        setSampleIsKeyframe()
        // Reset NAL unit type to avoid stale state
        nalUnitType = NalUnitUtil.H264NalUnitType.unspecified
        return sampleIsKeyframe
    }

    private func setSampleIsKeyframe() {
        let treatIFrameAsKeyframe = allowNonIdrKeyframes
            ? sliceHeader.isISlice()
            : randomAccessIndicator
        if nalUnitType == NalUnitUtil.H264NalUnitType.idr
            || (treatIFrameAsKeyframe && nalUnitType == NalUnitUtil.H264NalUnitType.nonIdr) {
            sampleIsKeyframe = true
        }
    }

    /// Takes ownership of the sample that just ended and outputs the previously held back one, whose
    /// duration is now known.
    private func completeSample() throws {
        guard let blockBuffer = try accumulator.commit() else { return }
        guard sampleTime.isNumeric, nalUnitStartPosition != samplePosition else {
            return
        }

        try delayedOutput.output(
            data: blockBuffer,
            time: sampleTime,
            decodeTime: sampleDecodeTime,
            flags: sampleIsKeyframe ? .keyframe : []
        )
    }

    /// Outputs the sample held back for duration derivation, estimating its duration. Called when no
    /// further sample will follow it, i.e. at the end of the input.
    func flushPendingSample() throws {
        try delayedOutput.flush()
    }
}

private struct SliceHeaderData {
    private static let sliceTypeI = 2
    private static let sliceTypeAllI = 7

    private var isComplete = false
    private var hasSliceType = false

    private var spsData: NalUnitUtil.SpsData?
    private var nalRefIdc = 0
    private var sliceType = 0
    private var frameNum = 0
    private var picParameterSetId = 0
    private var fieldPicFlag = false
    private var bottomFieldFlagPresent = false
    private var bottomFieldFlag = false
    private var idrPicFlag = false
    private var idrPicId = 0
    private var picOrderCntLsb = 0
    private var deltaPicOrderCntBottom = 0
    private var deltaPicOrderCnt0 = 0
    private var deltaPicOrderCnt1 = 0

    mutating func clear() {
        hasSliceType = false
        isComplete = false
    }

    mutating func setSliceType(_ sliceType: Int) {
        self.sliceType = sliceType
        hasSliceType = true
    }

    mutating func setAll(
        spsData: NalUnitUtil.SpsData,
        nalRefIdc: Int,
        sliceType: Int,
        frameNum: Int,
        picParameterSetId: Int,
        fieldPicFlag: Bool,
        bottomFieldFlagPresent: Bool,
        bottomFieldFlag: Bool,
        idrPicFlag: Bool,
        idrPicId: Int,
        picOrderCntLsb: Int,
        deltaPicOrderCntBottom: Int,
        deltaPicOrderCnt0: Int,
        deltaPicOrderCnt1: Int
    ) {
        self.spsData = spsData
        self.nalRefIdc = nalRefIdc
        self.sliceType = sliceType
        self.frameNum = frameNum
        self.picParameterSetId = picParameterSetId
        self.fieldPicFlag = fieldPicFlag
        self.bottomFieldFlagPresent = bottomFieldFlagPresent
        self.bottomFieldFlag = bottomFieldFlag
        self.idrPicFlag = idrPicFlag
        self.idrPicId = idrPicId
        self.picOrderCntLsb = picOrderCntLsb
        self.deltaPicOrderCntBottom = deltaPicOrderCntBottom
        self.deltaPicOrderCnt0 = deltaPicOrderCnt0
        self.deltaPicOrderCnt1 = deltaPicOrderCnt1
        isComplete = true
        hasSliceType = true
    }

    func isISlice() -> Bool {
        hasSliceType && (sliceType == Self.sliceTypeAllI || sliceType == Self.sliceTypeI)
    }

    func isFirstVclNalUnitOfPicture(_ other: SliceHeaderData) -> Bool {
        guard isComplete else { return false }
        guard other.isComplete else { return true }
        // See ISO 14496-10 subsection 7.4.1.2.4.
        guard let spsData, let otherSpsData = other.spsData else { return true }
        return frameNum != other.frameNum
            || picParameterSetId != other.picParameterSetId
            || fieldPicFlag != other.fieldPicFlag
            || (bottomFieldFlagPresent
                && other.bottomFieldFlagPresent
                && bottomFieldFlag != other.bottomFieldFlag)
            || (nalRefIdc != other.nalRefIdc && (nalRefIdc == 0 || other.nalRefIdc == 0))
            || (spsData.picOrderCountType == 0
                && otherSpsData.picOrderCountType == 0
                && (picOrderCntLsb != other.picOrderCntLsb
                    || deltaPicOrderCntBottom != other.deltaPicOrderCntBottom))
            || (spsData.picOrderCountType == 1
                && otherSpsData.picOrderCountType == 1
                && (deltaPicOrderCnt0 != other.deltaPicOrderCnt0
                    || deltaPicOrderCnt1 != other.deltaPicOrderCnt1))
            || idrPicFlag != other.idrPicFlag
            || (idrPicFlag && idrPicId != other.idrPicId)
    }
}
