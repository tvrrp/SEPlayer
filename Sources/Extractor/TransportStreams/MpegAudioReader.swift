//
//  MpegAudioReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous MPEG audio byte stream (MPEG-1, 2 and 2.5, layers I to III) and extracts individual frames.
final class MpegAudioReader: ElementaryStreamReader {
    private enum State {
        case findingHeader
        case readingHeader
        case readingFrame
    }

    private let language: String?
    private let roleFlags: RoleFlags
    private let containerMimeType: MimeTypes
    /// Where the frames are copied to.
    private let sampleMemory = SampleMemory(blockSize: 64 * 1024) // 64 KB

    private var output: TrackOutput?
    private var formatId: String?

    private var state = State.findingHeader
    private var headerData: BlockBufferReader
    private var header = MpegAudioUtil.Header()
    private var frameBytesRead = 0
    private var hasOutputFormat = false
    private var lastByteWasFF = false
    private var frameDuration = CMTime.zero
    private var frameSize = 0
    private var time = CMTime.invalid

    init(language: String? = nil, roleFlags: RoleFlags = [], containerMimeType: MimeTypes) throws {
        self.language = language
        self.roleFlags = roleFlags
        self.containerMimeType = containerMimeType
        headerData = try BlockBufferReader()
    }

    func seek() {
        state = .findingHeader
        frameBytesRead = 0
        lastByteWasFF = false
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
            case .findingHeader:
                try findHeader(&data)
            case .readingHeader:
                try readHeaderRemainder(&data, output: output)
            case .readingFrame:
                try readFrameRemainder(&data, output: output)
            }
        }
    }

    /// Looks for the 11 set bits that start a frame header.
    private func findHeader(_ source: inout BlockBufferReader) throws {
        while source.readableBytes > 0 {
            let byte = try source.readInt(as: UInt8.self)
            let found = lastByteWasFF && byte & 0xE0 == 0xE0
            lastByteWasFF = byte == 0xFF
            if found {
                lastByteWasFF = false
                try headerData.clear()
                try headerData.extend(with: [0xFF, byte])
                frameBytesRead = 2
                state = .readingHeader
                return
            }
        }
    }

    private func readHeaderRemainder(_ source: inout BlockBufferReader, output: TrackOutput) throws {
        guard try headerData.fill(from: &source, upTo: Self.headerSize) else { return }
        frameBytesRead = Self.headerSize

        guard try header.setForHeaderData(Int(headerData.getInt(at: 0, as: UInt32.self))) else {
            // Not a header: look for the next one.
            frameBytesRead = 0
            state = .findingHeader
            return
        }

        frameSize = header.frameSize
        if !hasOutputFormat {
            frameDuration = CMTime(
                value: CMTimeValue(header.samplesPerFrame),
                timescale: CMTimeScale(header.sampleRate)
            )
            var format = AudioFormat(header: header)
            format.id = try formatId.checkNotNil()
            format.containerMimeType = containerMimeType
            format.language = language
            format.roleFlags = roleFlags
            try output.setFormat(AnyFormat(format))
            hasOutputFormat = true
        }
        try output.sampleData(data: sampleMemory.copy(headerData.blockBuffer))
        state = .readingFrame
    }

    private func readFrameRemainder(_ source: inout BlockBufferReader, output: TrackOutput) throws {
        let bytesToRead = min(source.readableBytes, frameSize - frameBytesRead)
        try output.sampleData(data: sampleMemory.copy(from: &source, length: bytesToRead))
        frameBytesRead += bytesToRead
        guard frameBytesRead >= frameSize else { return }

        // packetStarted must be called before a frame is read.
        try checkArgument(time.isNumeric)
        try output.sampleMetadata(
            time: CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
            flags: .keyframe,
            range: 0 ..< frameSize
        )
        time = time + frameDuration
        frameBytesRead = 0
        state = .findingHeader
    }
}

private extension MpegAudioReader {
    static let headerSize = 4
}
