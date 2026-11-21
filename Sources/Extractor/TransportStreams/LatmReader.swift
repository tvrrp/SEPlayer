//
//  LatmReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous AAC LATM/LOAS byte stream (ISO/IEC 14496-3, 1.7) and extracts individual frames.
final class LatmReader: ElementaryStreamReader {
    private enum State {
        case findingSync1
        case findingSync2
        case readingHeader
        case readingSample
    }

    private let language: String?
    private let roleFlags: RoleFlags
    private let containerMimeType: MimeTypes
    /// Where the frames are copied to.
    private let sampleMemory = SampleMemory(blockSize: 64 * 1024) // 64 KB

    private var output: TrackOutput?
    private var formatId: String?
    private var format: AudioFormat?

    private var state = State.findingSync1
    /// The audio mux element that is being read.
    private var muxElement: BlockBufferReader
    private var sampleSize = 0
    private var secondHeaderByte = 0
    private var time = CMTime.invalid
    private var streamMuxRead = false
    private var audioMuxVersionA = 0
    private var numSubframes = 0
    private var frameLengthType = 0
    private var otherDataPresent = false
    private var otherDataLengthBits = 0
    private var sampleDuration = CMTime.zero

    init(language: String? = nil, roleFlags: RoleFlags = [], containerMimeType: MimeTypes) throws {
        self.language = language
        self.roleFlags = roleFlags
        self.containerMimeType = containerMimeType
        muxElement = try BlockBufferReader()
    }

    func seek() {
        state = .findingSync1
        time = .invalid
        streamMuxRead = false
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        self.output = try output.track(for: idGenerator.getTrackId(), trackType: .audio)
        formatId = try idGenerator.getFormatId()
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        time = pesTime
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        while data.readableBytes > 0 {
            switch state {
            case .findingSync1:
                if try data.readInt(as: UInt8.self) == Self.syncByteFirst {
                    state = .findingSync2
                }
            case .findingSync2:
                let secondByte = try Int(data.readInt(as: UInt8.self))
                if secondByte & Self.syncByteSecond == Self.syncByteSecond {
                    secondHeaderByte = secondByte
                    state = .readingHeader
                } else if secondByte != Self.syncByteFirst {
                    state = .findingSync1
                }
            case .readingHeader:
                // audioMuxLengthBytes: the 13 bits after the 11-bit sync word.
                sampleSize = try (secondHeaderByte & ~Self.syncByteSecond) << 8 | Int(data.readInt(as: UInt8.self))
                try muxElement.clear()
                state = .readingSample
            case .readingSample:
                if try muxElement.fill(from: &data, upTo: sampleSize) {
                    var bits = BlockBufferBitReader(reader: muxElement)
                    try parseAudioMuxElement(&bits, output: output)
                    state = .findingSync1
                }
            }
        }
    }

    private func parseAudioMuxElement(_ data: inout BlockBufferBitReader, output: TrackOutput) throws {
        let useSameStreamMux = try data.readBit()
        if !useSameStreamMux {
            streamMuxRead = true
            try parseStreamMuxConfig(&data, output: output)
        } else if !streamMuxRead {
            // Nothing can be read without a StreamMuxConfig.
            return
        }

        guard audioMuxVersionA == 0, numSubframes == 0 else {
            throw ParserError.createForMalformedContainer(message: "Unsupported LATM audio mux element")
        }
        let muxSlotLengthBytes = try parsePayloadLengthInfo(&data)
        try parsePayloadMux(&data, muxLengthBytes: muxSlotLengthBytes, output: output)
        if otherDataPresent {
            data.skipBits(otherDataLengthBits)
        }
    }

    private func parseStreamMuxConfig(_ data: inout BlockBufferBitReader, output: TrackOutput) throws {
        let audioMuxVersion = try data.readBits(1)
        audioMuxVersionA = audioMuxVersion == 1 ? try data.readBits(1) : 0
        guard audioMuxVersionA == 0 else {
            throw ParserError.createForMalformedContainer(message: "Unsupported LATM audioMuxVersionA")
        }
        if audioMuxVersion == 1 {
            _ = try latmGetValue(&data) // taraBufferFullness
        }
        guard try data.readBit() else { // allStreamsSameTimeFraming
            throw ParserError.createForMalformedContainer(message: "Unsupported LATM time framing")
        }
        numSubframes = try data.readBits(6)
        let numProgram = try data.readBits(4)
        let numLayer = try data.readBits(3)
        guard numProgram == 0, numLayer == 0 else {
            throw ParserError.createForMalformedContainer(message: "Unsupported LATM programs or layers")
        }

        if audioMuxVersion == 0 {
            let startPosition = data.position
            let config = try AudioSpecificConfig(bits: &data, isLastInData: false)
            let length = data.position - startPosition
            data.setPosition(startPosition)
            try updateFormat(config: config, bytes: data.readBits(numBits: length), output: output)
        } else {
            let length = try latmGetValue(&data)
            let startPosition = data.position
            _ = try AudioSpecificConfig(bits: &data, isLastInData: false)
            data.skipBits(length - (data.position - startPosition)) // fillBits
        }

        try parseFrameLength(&data)
        otherDataPresent = try data.readBit()
        otherDataLengthBits = 0
        if otherDataPresent {
            if audioMuxVersion == 1 {
                otherDataLengthBits = try latmGetValue(&data)
            } else {
                var otherDataLengthEscape: Bool
                repeat {
                    otherDataLengthEscape = try data.readBit()
                    otherDataLengthBits = try (otherDataLengthBits << 8) + data.readBits(8)
                } while otherDataLengthEscape
            }
        }
        if try data.readBit() { // crcCheckPresent
            data.skipBits(8) // crcCheckSum
        }
    }

    private func parseFrameLength(_ data: inout BlockBufferBitReader) throws {
        frameLengthType = try data.readBits(3)
        switch frameLengthType {
        case 0: data.skipBits(8) // latmBufferFullness
        case 1: data.skipBits(9) // frameLength
        case 3,
             4,
             5: data.skipBits(6) // CELPframeLengthTableIndex
        case 6,
             7: data.skipBits(1) // HVXCframeLengthTableIndex
        default:
            throw ParserError.createForMalformedContainer(message: "Invalid LATM frameLengthType \(frameLengthType)")
        }
    }

    /// Sets the format of the stream of an AudioSpecificConfig, if it isn't the one set.
    ///
    /// - Parameter bytes: The bits of the config, padded to whole bytes.
    private func updateFormat(config: AudioSpecificConfig, bytes: [UInt8], output: TrackOutput) throws {
        var format = try AudioFormat(audioSpecificConfig: bytes)
        format.id = try formatId.checkNotNil()
        format.containerMimeType = containerMimeType
        format.language = language
        format.roleFlags = roleFlags
        guard format != self.format else { return }
        self.format = format
        // A sample is an access unit: the frames of a packet, at the rate of the core.
        sampleDuration = CMTime(value: CMTimeValue(config.frameLength ?? 1024), timescale: CMTimeScale(config.sampleRate))
        try output.setFormat(AnyFormat(format))
    }

    private func parsePayloadLengthInfo(_ data: inout BlockBufferBitReader) throws -> Int {
        guard frameLengthType == 0 else {
            throw ParserError.createForMalformedContainer(message: "Unsupported LATM frameLengthType \(frameLengthType)")
        }
        var muxSlotLengthBytes = 0
        var value: Int
        repeat {
            value = try data.readBits(8)
            muxSlotLengthBytes += value
        } while value == 255
        return muxSlotLengthBytes
    }

    private func parsePayloadMux(_ data: inout BlockBufferBitReader, muxLengthBytes: Int, output: TrackOutput) throws {
        if data.isByteAligned {
            var payload = try data.readSlice(length: muxLengthBytes)
            try output.sampleData(data: sampleMemory.copy(from: &payload, length: muxLengthBytes))
        } else {
            // The payload starts in the middle of a byte: its bits are moved to whole bytes.
            let payload = try data.readBits(numBits: muxLengthBytes * 8)
            try output.sampleData(data: payload.withUnsafeBytes(sampleMemory.copy(bytes:)))
        }
        // packetStarted must be called before a frame is read.
        try checkArgument(time.isNumeric)
        try output.sampleMetadata(
            time: CMSampleTimingInfo(duration: sampleDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
            flags: .keyframe,
            range: 0 ..< muxLengthBytes
        )
        time = time + sampleDuration
    }

    private func latmGetValue(_ data: inout BlockBufferBitReader) throws -> Int {
        let bytesForValue = try data.readBits(2)
        return try data.readBits((bytesForValue + 1) * 8)
    }
}

private extension LatmReader {
    static let syncByteFirst: UInt8 = 0x56
    static let syncByteSecond = 0xE0
}
