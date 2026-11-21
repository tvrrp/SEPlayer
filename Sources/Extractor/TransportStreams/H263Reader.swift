//
//  H263Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses an ISO/IEC 14496-2 (MPEG-4 Part 2) or ITU-T Recommendation H.263 byte stream and extracts individual
/// frames.
final class H263Reader: ElementaryStreamReader {
    private let userDataReader: UserDataReader?
    private let containerMimeType: MimeTypes
    private let allocator: CFAllocator
    private let userData: NalUnitTargetBuffer?
    private let csdBuffer: CsdBuffer
    private let sampleBuffer: StartCodeSampleBuffer

    private var sampleReader: SampleReader?
    private var formatId: String?
    private var output: TrackOutput?
    private var prefixFlags: (Bool, Bool, Bool) = (false, false, false)
    private var totalBytesWritten = 0
    private var hasOutputFormat = false
    private var pesTime = CMTime.invalid
    private var pesDecodeTime = CMTime.invalid

    init(userDataReader: UserDataReader?, containerMimeType: MimeTypes, memoryPool: CMMemoryPool = CMMemoryPool()) throws {
        self.userDataReader = userDataReader
        self.containerMimeType = containerMimeType
        allocator = memoryPool.allocator
        csdBuffer = try CsdBuffer()
        sampleBuffer = try StartCodeSampleBuffer(memoryPool: memoryPool)
        userData = userDataReader == nil
            ? nil
            : try NalUnitTargetBuffer(targetType: StartCode.userData, memoryPool: memoryPool)
    }

    func seek() {
        prefixFlags = (false, false, false)
        csdBuffer.reset()
        sampleReader?.reset()
        sampleBuffer.reset()
        userData?.reset()
        userDataReader?.clear()
        totalBytesWritten = 0
        pesTime = .invalid
        pesDecodeTime = .invalid
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .video)
        self.output = trackOutput
        sampleReader = SampleReader(trackOutput: trackOutput, sampleBuffer: sampleBuffer)
        try userDataReader?.createTracks(extractorOutput: output, idGenerator: idGenerator)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        self.pesTime = pesTime
        pesDecodeTime = decodeTime
    }

    func consume(data: inout BlockBufferReader) throws {
        let sampleReader = try sampleReader.checkNotNil()
        let output = try output.checkNotNil()
        guard data.readableBytes > 0 else { return }
        let view = data.readableBytesView
        var offset = view.startIndex
        let limit = view.endIndex
        defer { data.moveReaderIndex(to: limit) }
        totalBytesWritten += view.count
        try sampleBuffer.append(view)

        while true {
            let startCodeOffset = view.withContiguousStorageIfAvailable { bytes in
                let base = view.startIndex
                return base + NalUnitUtil.findNalUnit(bytes, offset: offset - base, limit: limit - base, prefixFlags: &prefixFlags)
            } ?? limit
            if startCodeOffset == limit {
                if !hasOutputFormat {
                    try csdBuffer.onData(view[offset ..< limit])
                }
                sampleReader.onData(view[offset ..< limit])
                try userData?.appendToNalUnit(view[offset ..< limit])
                return
            }

            let startCodeValue = Int(view[startCodeOffset + 3])
            let lengthToStartCode = startCodeOffset - offset
            if !hasOutputFormat {
                if lengthToStartCode > 0 {
                    try csdBuffer.onData(view[offset ..< startCodeOffset])
                }
                let bytesAlreadyPassed = lengthToStartCode < 0 ? -lengthToStartCode : 0
                if try csdBuffer.onStartCode(startCodeValue, bytesAlreadyPassed: bytesAlreadyPassed) {
                    try output.setFormat(AnyFormat(parseCsdBuffer()))
                    hasOutputFormat = true
                }
            }
            if lengthToStartCode > 0 {
                sampleReader.onData(view[offset ..< startCodeOffset])
            }

            if let userData, let userDataReader {
                var bytesAlreadyPassed = 0
                if lengthToStartCode > 0 {
                    try userData.appendToNalUnit(view[offset ..< startCodeOffset])
                } else {
                    bytesAlreadyPassed = -lengthToStartCode
                }
                if userData.endNalUnit(discardPadding: bytesAlreadyPassed) {
                    let unescaped = try NalUnitUtil.unescapeStream(
                        userData.nalBuffer,
                        length: userData.nalLength,
                        allocator: allocator
                    )
                    var userDataBuffer = BlockBufferReader(unescaped)
                    try userDataReader.consume(pesTime: pesTime, userData: &userDataBuffer)
                }
                if startCodeValue == StartCode.userData, view[startCodeOffset + 2] == 0x01 {
                    userData.startNalUnit(type: startCodeValue)
                }
            }

            let bytesWrittenPastPosition = limit - startCodeOffset
            let absolutePosition = totalBytesWritten - bytesWrittenPastPosition
            try sampleReader.onDataEnd(position: absolutePosition, hasOutputFormat: hasOutputFormat)
            sampleReader.onStartCode(startCodeValue, time: pesTime, decodeTime: pesDecodeTime)
            offset = startCodeOffset + 3
        }
    }

    func endOfInputReached() throws {
        let sampleReader = try sampleReader.checkNotNil()
        try sampleReader.onDataEnd(position: totalBytesWritten, hasOutputFormat: hasOutputFormat)
        try sampleReader.flush()
        sampleReader.reset()
        try userDataReader?.flush()
    }

    /// The format of the visual object sequence, visual object and video object layer headers, ISO/IEC 14496-2 6.2.3.
    private func parseCsdBuffer() throws -> VideoFormat {
        var buffer = BlockBufferBitReader(reader: csdBuffer.data)
        buffer.skipBits(8 * csdBuffer.volStartPosition)
        buffer.skipBits(32) // video_object_layer_start_code
        buffer.skipBit() // random_accessible_vol
        buffer.skipBits(8) // video_object_type_indication
        if try buffer.readBit() { // is_object_layer_identifier
            buffer.skipBits(4) // video_object_layer_verid
            buffer.skipBits(3) // video_object_layer_priority
        }

        var pixelWidthHeightRatio: Float = 1
        let aspectRatioInfo = try buffer.readBits(4)
        if aspectRatioInfo == 0x0F { // extended_PAR
            let parWidth = try buffer.readBits(8)
            let parHeight = try buffer.readBits(8)
            if parHeight == 0 {
                SELogger.warning(.transportStream, "Invalid aspect ratio")
            } else {
                pixelWidthHeightRatio = Float(parWidth) / Float(parHeight)
            }
        } else if aspectRatioInfo < Self.pixelWidthHeightRatioByAspectRatioInfo.count {
            pixelWidthHeightRatio = Self.pixelWidthHeightRatioByAspectRatioInfo[aspectRatioInfo]
        } else {
            SELogger.warning(.transportStream, "Invalid aspect ratio")
        }

        if try buffer.readBit() { // vol_control_parameters
            buffer.skipBits(2) // chroma_format
            buffer.skipBits(1) // low_delay
            if try buffer.readBit() { // vbv_parameters
                // first_half_bit_rate, marker, latter_half_bit_rate, marker, first_half_vbv_buffer_size, marker,
                // latter_half_vbv_buffer_size, first_half_vbv_occupancy, marker, latter_half_vbv_occupancy, marker.
                buffer.skipBits(15 + 1 + 15 + 1 + 15 + 1 + 3 + 11 + 1 + 15 + 1)
            }
        }
        let videoObjectLayerShape = try buffer.readBits(2)
        if videoObjectLayerShape != 0 {
            SELogger.warning(.transportStream, "Unhandled video object layer shape")
        }
        buffer.skipBit() // marker_bit
        var vopTimeIncrementResolution = try buffer.readBits(16)
        buffer.skipBit() // marker_bit
        if try buffer.readBit() { // fixed_vop_rate
            if vopTimeIncrementResolution == 0 {
                SELogger.warning(.transportStream, "Invalid vop_increment_time_resolution")
            } else {
                vopTimeIncrementResolution -= 1
                var numBits = 0
                while vopTimeIncrementResolution > 0 {
                    numBits += 1
                    vopTimeIncrementResolution >>= 1
                }
                buffer.skipBits(numBits) // fixed_vop_time_increment
            }
        }
        buffer.skipBit() // marker_bit
        let width = try buffer.readBits(13)
        buffer.skipBit() // marker_bit
        let height = try buffer.readBits(13)

        // The decoder takes the headers as they are, as the decoder specific info of the elementary stream
        // descriptor of an `esds` box: its version and flags, then the descriptor.
        let esds = Data([0, 0, 0, 0] + ElementaryStreamDescriptor.bytes(
            objectTypeIndication: Self.mpeg4VisualObjectType,
            streamType: Self.visualStreamType,
            decoderSpecificInfo: csdBuffer.data.readableBytesView
        ))
        let esdsReader = try BlockBufferReader(bytes: esds)
        var format = VideoFormat()
        format.codecType = FourCharacterCode(kCMVideoCodecType_MPEG4Video)
        format.size = VideoSize(width: width, height: height)
        format.boxes = [MediaBox(type: "esds", payload: esds)]
        try format.readCodec { $0 == .esds ? esdsReader : nil }
        format.id = try formatId.checkNotNil()
        format.containerMimeType = containerMimeType
        format.size = VideoSize(width: width, height: height, pixelWidthHeightRatio: pixelWidthHeightRatio)
        return format
    }
}

private extension H263Reader {
    /// The objectTypeIndication of MPEG-4 Visual.
    static let mpeg4VisualObjectType = 0x20
    /// The streamType of visual streams.
    static let visualStreamType = 4

    enum StartCode {
        static let visualObjectSequence = 0xB0
        static let userData = 0xB2
        static let groupOfVop = 0xB3
        static let visualObject = 0xB5
        static let vop = 0xB6
        static let maxVideoObject = 0x1F
    }

    static let pixelWidthHeightRatioByAspectRatioInfo: [Float] = [1, 1, 12 / 11, 10 / 11, 16 / 11, 40 / 33, 1]
    static let startCodePrefix: [UInt8] = [0, 0, 1]

    /// Collects the visual object sequence header up to the first VOP.
    final class CsdBuffer {
        private enum State {
            case skipToVisualObjectSequenceStart
            case expectVisualObjectStart
            case expectVideoObjectStart
            case expectVideoObjectLayerStart
            case waitForVopStart
        }

        private(set) var data: BlockBufferReader
        private(set) var volStartPosition = 0
        private var isFilling = false
        private var state = State.skipToVisualObjectSequenceStart

        init() throws {
            data = try BlockBufferReader()
        }

        func reset() {
            isFilling = false
            state = .skipToVisualObjectSequenceStart
        }

        /// - Returns: Whether the headers are complete.
        func onStartCode(_ startCodeValue: Int, bytesAlreadyPassed: Int) throws -> Bool {
            switch state {
            case .skipToVisualObjectSequenceStart:
                if startCodeValue == StartCode.visualObjectSequence {
                    state = .expectVisualObjectStart
                    isFilling = true
                    try data.clear()
                }
            case .expectVisualObjectStart:
                if startCodeValue != StartCode.visualObject {
                    SELogger.warning(.transportStream, "Unexpected start code value")
                    reset()
                } else {
                    state = .expectVideoObjectStart
                }
            case .expectVideoObjectStart:
                if startCodeValue > StartCode.maxVideoObject {
                    SELogger.warning(.transportStream, "Unexpected start code value")
                    reset()
                } else {
                    state = .expectVideoObjectLayerStart
                }
            case .expectVideoObjectLayerStart:
                if startCodeValue & 0xF0 != 0x20 {
                    SELogger.warning(.transportStream, "Unexpected start code value")
                    reset()
                } else {
                    volStartPosition = data.capacity
                    state = .waitForVopStart
                }
            case .waitForVopStart:
                if startCodeValue == StartCode.groupOfVop || startCodeValue == StartCode.visualObject {
                    // The last bytes are the start of this start code.
                    data = try data.getSlice(at: 0, length: max(data.capacity - bytesAlreadyPassed, 0))
                    isFilling = false
                    return true
                }
            }
            try onData(H263Reader.startCodePrefix)
            return false
        }

        func onData<C: Collection<UInt8>>(_ newData: C) throws {
            guard isFilling, !newData.isEmpty else { return }
            try data.extend(with: newData)
        }
    }

    /// Finds where VOPs start and end, and writes them.
    final class SampleReader {
        private let delayedOutput: DelayedSampleOutput
        private let sampleBuffer: StartCodeSampleBuffer

        private var readingSample = false
        private var lookingForVopCodingType = false
        private var sampleIsKeyframe = false
        private var startCodeValue: Int?
        private var vopBytesRead = 0
        private var samplePosition = 0
        private var sampleTime = CMTime.invalid
        private var sampleDecodeTime = CMTime.invalid

        init(trackOutput: TrackOutput, sampleBuffer: StartCodeSampleBuffer) {
            delayedOutput = DelayedSampleOutput(trackOutput: trackOutput)
            self.sampleBuffer = sampleBuffer
        }

        func reset() {
            readingSample = false
            lookingForVopCodingType = false
            sampleIsKeyframe = false
            startCodeValue = nil
            delayedOutput.reset()
        }

        func flush() throws {
            try delayedOutput.flush()
        }

        func onStartCode(_ startCodeValue: Int, time: CMTime, decodeTime: CMTime) {
            self.startCodeValue = startCodeValue
            sampleIsKeyframe = false
            readingSample = startCodeValue == StartCode.vop || startCodeValue == StartCode.groupOfVop
            lookingForVopCodingType = startCodeValue == StartCode.vop
            vopBytesRead = 0
            sampleTime = time
            sampleDecodeTime = decodeTime
        }

        /// Reads vop_coding_type, the two bits after the VOP start code.
        func onData(_ data: BlockBufferView) {
            guard lookingForVopCodingType else { return }
            let headerOffset = Self.offsetVopCodingType - vopBytesRead
            if headerOffset < data.count {
                sampleIsKeyframe = (data[data.startIndex + headerOffset] & 0xC0) >> 6 == Self.vopCodingTypeIntra
                lookingForVopCodingType = false
            } else {
                vopBytesRead += data.count
            }
        }

        /// Called at a start code, at `position` in the stream: a VOP that was read ends there.
        func onDataEnd(position: Int, hasOutputFormat: Bool) throws {
            if startCodeValue == StartCode.vop, hasOutputFormat, readingSample, sampleTime.isNumeric,
               let sample = try sampleBuffer.take(upTo: position) {
                try delayedOutput.output(
                    data: sample,
                    time: sampleTime,
                    decodeTime: sampleDecodeTime,
                    flags: sampleIsKeyframe ? .keyframe : []
                )
            }
            if startCodeValue != StartCode.groupOfVop {
                // The headers of a group of VOPs go with the VOP after them.
                try sampleBuffer.discard(upTo: position)
                samplePosition = position
            }
        }

        private static let offsetVopCodingType = 1
        private static let vopCodingTypeIntra = 0
    }
}
