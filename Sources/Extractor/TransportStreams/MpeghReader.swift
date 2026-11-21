//
//  MpeghReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous MPEG-H 3D audio stream in MHAS packets (ISO/IEC 23008-3) and extracts frames: the packets up
/// to and including an `mpegh3daFrame` one.
final class MpeghReader: ElementaryStreamReader {
    private enum State {
        case findingSync
        case readingPacketHeader
        case readingPacketPayload
    }

    private typealias PacketType = MpeghUtil.MhasPacketHeader.PacketType

    private let containerMimeType: MimeTypes
    /// Where the packets are copied to.
    private let sampleMemory = SampleMemory(blockSize: 64 * 1024) // 64 KB

    private var formatId: String?
    private var output: TrackOutput?

    private var state = State.findingSync
    private var headerData: BlockBufferReader
    /// The bytes of a packet header read before it is parsed: it grows until the header can be read.
    private var headerLimit = MpeghReader.minPacketHeaderSize
    /// The payload of a config or truncation packet, which is read besides being written.
    private var payload: BlockBufferReader
    private var time = CMTime.invalid
    private var pendingTime = CMTime.invalid
    private var dataPending = false
    private var randomAccessPointPending = true
    private var flags: TsPayload.PacketIndicators = []
    private var syncBytes = 0
    private var headerDataFinished = true
    private var payloadBytesRead = 0
    private var frameBytes = 0
    private var header = MpeghUtil.MhasPacketHeader()
    private var samplingRate = 0
    private var standardFrameLength = 0
    private var truncationSamples = 0
    private var mainStreamLabel: Int64?
    private var configFound = false

    init(containerMimeType: MimeTypes) throws {
        self.containerMimeType = containerMimeType
        headerData = try BlockBufferReader()
        payload = try BlockBufferReader()
    }

    func seek() {
        state = .findingSync
        syncBytes = 0
        headerLimit = Self.minPacketHeaderSize
        payloadBytesRead = 0
        frameBytes = 0
        samplingRate = 0
        standardFrameLength = 0
        truncationSamples = 0
        mainStreamLabel = nil
        configFound = false
        dataPending = false
        headerDataFinished = true
        randomAccessPointPending = true
        time = .invalid
        pendingTime = .invalid
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        self.output = try output.track(for: idGenerator.getTrackId(), trackType: .audio)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        self.flags = flags
        // A packet that starts in the middle of a frame gives the time of the next one.
        if !randomAccessPointPending, frameBytes != 0 || !headerDataFinished {
            dataPending = true
        }
        guard pesTime.isNumeric else { return }
        if dataPending {
            pendingTime = pesTime
        } else {
            time = pesTime
        }
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        while data.readableBytes > 0 {
            switch state {
            case .findingSync:
                if try skipToNextSync(&data) {
                    try headerData.clear()
                    state = .readingPacketHeader
                }
            case .readingPacketHeader:
                guard try headerData.fill(from: &data, upTo: headerLimit) else {
                    headerDataFinished = false
                    break
                }
                if try parseHeader() {
                    try output.sampleData(data: sampleMemory.copy(headerData.blockBuffer))
                    try headerData.clear()
                    headerLimit = Self.minPacketHeaderSize
                    try payload.clear()
                    headerDataFinished = true
                    state = .readingPacketPayload
                } else if headerLimit < Self.maxPacketHeaderSize {
                    headerLimit += 1
                    headerDataFinished = false
                } else {
                    throw ParserError.createForMalformedContainer(message: "MHAS packet header longer than allowed")
                }
            case .readingPacketPayload:
                let bytesToRead = min(data.readableBytes, header.packetLength - payloadBytesRead)
                let sampleData = try sampleMemory.copy(from: &data, length: bytesToRead)
                if header.packetType == PacketType.mpegh3daConfig || header.packetType == PacketType.audioTruncation {
                    try payload.extend(with: sampleData)
                }
                try output.sampleData(data: sampleData)
                payloadBytesRead += bytesToRead
                guard payloadBytesRead == header.packetLength else { break }

                switch header.packetType {
                case PacketType.mpegh3daConfig:
                    try parseConfig(output: output)
                case PacketType.audioTruncation:
                    var bits = BlockBufferBitReader(reader: payload)
                    truncationSamples = try MpeghUtil.parseAudioTruncationInfo(&bits)
                case PacketType.mpegh3daFrame:
                    try finalizeFrame(output: output)
                default:
                    break
                }
                state = .readingPacketHeader
            }
        }
    }

    private func skipToNextSync(_ data: inout BlockBufferReader) throws -> Bool {
        // Frames start at random access points.
        guard flags.contains(.randomAccess) else {
            data.moveReaderIndex(forwardBy: data.readableBytes)
            return false
        }
        // An aligned packet starts with a packet header.
        guard !flags.contains(.dataAlignment) else { return true }

        while data.readableBytes > 0 {
            syncBytes = try (syncBytes << 8 | Int(data.readInt(as: UInt8.self))) & 0xFFFF_FFFF
            if MpeghUtil.isSyncWord(syncBytes) {
                // The sync word is the start of a packet: read it as one.
                data.moveReaderIndex(to: data.readerIndex - Self.syncWordLength)
                syncBytes = 0
                return true
            }
        }
        return false
    }

    private func parseHeader() throws -> Bool {
        var bits = BlockBufferBitReader(reader: headerData)
        guard try MpeghUtil.parseMhasPacketHeader(&bits, header: &header) else { return false }
        payloadBytesRead = 0
        frameBytes += header.packetLength + headerData.capacity
        return true
    }

    private func parseConfig(output: TrackOutput) throws {
        var bits = BlockBufferBitReader(reader: payload)
        let config = try MpeghUtil.parseMpegh3daConfig(&bits)
        samplingRate = config.samplingFrequency
        standardFrameLength = config.standardFrameLength
        if mainStreamLabel != header.packetLabel {
            mainStreamLabel = header.packetLabel
            let codecs = "mhm1" + String(format: ".%02X", config.profileLevelIndication)
            // MHAS packets carry their own config.
            var format = AudioFormat()
            format.codec = AudioCodec(.audioMPEGHMHM1, \.mpegH) { $0.profileLevelIndication = config.profileLevelIndication }
            format.sampleRate = samplingRate
            format.id = try formatId.checkNotNil()
            format.containerMimeType = containerMimeType
            format.codecs = codecs
            try output.setFormat(AnyFormat(format))
        }
        configFound = true
    }

    private func finalizeFrame(output: TrackOutput) throws {
        let duration = samplingRate > 0
            ? CMTime(value: CMTimeValue(standardFrameLength - truncationSamples), timescale: CMTimeScale(samplingRate))
            : .zero
        let frameTime = time
        if dataPending {
            dataPending = false
            time = pendingTime
        } else {
            time = time + duration
        }
        try output.sampleMetadata(
            time: CMSampleTimingInfo(duration: duration, presentationTimeStamp: frameTime, decodeTimeStamp: .invalid),
            flags: configFound ? .keyframe : [],
            range: 0 ..< frameBytes
        )
        if configFound {
            randomAccessPointPending = false
        }
        configFound = false
        truncationSamples = 0
        frameBytes = 0
    }
}

private extension MpeghReader {
    static let syncWordLength = 3
    static let minPacketHeaderSize = 2
    static let maxPacketHeaderSize = 15
}
