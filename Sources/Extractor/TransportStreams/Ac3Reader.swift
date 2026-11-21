//
//  Ac3Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous (E-)AC-3 byte stream and extracts individual sync frames.
final class Ac3Reader: ElementaryStreamReader {
    private enum State {
        case findingSync
        case readingHeader
        case readingSample
    }

    private let language: String?
    private let roleFlags: RoleFlags
    private let containerMimeType: MimeTypes
    /// Where the frames are copied to.
    private let sampleMemory = SampleMemory(blockSize: 64 * 1024) // 64 KB

    private var formatId: String?
    private var output: TrackOutput?

    private var state = State.findingSync
    private var header: BlockBufferReader
    private var bytesRead = 0
    private var lastByteWas0B = false
    private var sampleDuration = CMTime.zero
    private var format: AudioFormat?
    /// The channels and the rate of the frames the format was made for.
    private var formatFrame: (channelCount: Int, sampleRate: Int)?
    private var sampleSize = 0
    private var time = CMTime.invalid

    init(language: String? = nil, roleFlags: RoleFlags = [], containerMimeType: MimeTypes) throws {
        self.language = language
        self.roleFlags = roleFlags
        self.containerMimeType = containerMimeType
        header = try BlockBufferReader()
    }

    func seek() {
        state = .findingSync
        bytesRead = 0
        lastByteWas0B = false
        time = .invalid
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        self.output = try output.track(for: idGenerator.getTrackId(), trackType: .audio)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        time = pesTime
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        while data.readableBytes > 0 {
            switch state {
            case .findingSync:
                if try skipToNextSync(&data) {
                    state = .readingHeader
                    try header.clear()
                    try header.extend(with: Self.syncWord)
                }
            case .readingHeader:
                if try header.fill(from: &data, upTo: Self.headerSize) {
                    try parseHeader(output: output)
                    try output.sampleData(data: sampleMemory.copy(header.blockBuffer))
                    bytesRead = Self.headerSize
                    state = .readingSample
                }
            case .readingSample:
                let bytesToRead = min(data.readableBytes, sampleSize - bytesRead)
                try output.sampleData(data: sampleMemory.copy(from: &data, length: bytesToRead))
                bytesRead += bytesToRead
                if bytesRead >= sampleSize {
                    // packetStarted must be called before a frame is read.
                    try checkArgument(time.isNumeric)
                    try output.sampleMetadata(
                        time: CMSampleTimingInfo(
                            duration: sampleDuration,
                            presentationTimeStamp: time,
                            decodeTimeStamp: .invalid
                        ),
                        flags: .keyframe,
                        range: 0 ..< sampleSize
                    )
                    time = time + sampleDuration
                    state = .findingSync
                }
            }
        }
    }

    /// Moves past the next sync word, 0x0B77.
    ///
    /// - Returns: Whether one was found.
    private func skipToNextSync(_ data: inout BlockBufferReader) throws -> Bool {
        while data.readableBytes > 0 {
            let byte = try data.readInt(as: UInt8.self)
            guard lastByteWas0B else {
                lastByteWas0B = byte == Self.syncWord[0]
                continue
            }
            if byte == Self.syncWord[1] {
                lastByteWas0B = false
                return true
            }
            lastByteWas0B = byte == Self.syncWord[0]
        }
        return false
    }

    private func parseHeader(output: TrackOutput) throws {
        var bits = BlockBufferBitReader(reader: header)
        let frameInfo = try Ac3Util.parseAc3SyncFrameInfo(&bits)
        if format == nil
            || frameInfo.channelCount != formatFrame?.channelCount
            || frameInfo.sampleRate != formatFrame?.sampleRate
            || frameInfo.mimeType != format?.codec?.mimeType {
            // The frames describe themselves: the codec needs no config. A frame that mustn't be decoded has no
            // codec.
            var format = AudioFormat()
            format.codec = frameInfo.mimeType.map(AudioCodec.init)
            format.sampleRate = frameInfo.sampleRate
            format.channelCount = frameInfo.channelCount
            format.id = try formatId.checkNotNil()
            format.containerMimeType = containerMimeType
            format.language = language
            format.roleFlags = roleFlags
            format.peakBitrate = frameInfo.bitrate
            if frameInfo.mimeType == .audioAC3 {
                format.averageBitrate = frameInfo.bitrate
            }
            self.format = format
            formatFrame = (frameInfo.channelCount, frameInfo.sampleRate)
            try output.setFormat(AnyFormat(format))
        }
        sampleSize = frameInfo.frameSize
        sampleDuration = CMTime(value: CMTimeValue(frameInfo.sampleCount), timescale: CMTimeScale(frameInfo.sampleRate))
    }
}

private extension Ac3Reader {
    /// The bytes of the header that are read before the frame is: enough for every field of an E-AC-3 header.
    static let headerSize = 128
    static let syncWord: [UInt8] = [0x0B, 0x77]
}
