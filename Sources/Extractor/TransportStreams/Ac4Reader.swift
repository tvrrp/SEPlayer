//
//  Ac4Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.Ac4Reader
//  Copyright (C) 2019 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous AC-4 byte stream and extracts individual sync frames.
final class Ac4Reader: ElementaryStreamReader {
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
    private var lastByteWasAC = false
    private var hasCrc = false
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
        lastByteWasAC = false
        hasCrc = false
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
                    try header.extend(with: [0xAC, hasCrc ? 0x41 : 0x40])
                }
            case .readingHeader:
                if try header.fill(from: &data, upTo: Ac4Util.headerSizeForParser) {
                    try parseHeader(output: output)
                    try output.sampleData(data: sampleMemory.copy(header.blockBuffer))
                    bytesRead = Ac4Util.headerSizeForParser
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
                        SampleProperties(
                            timingInfo: CMSampleTimingInfo(
                                duration: sampleDuration,
                                presentationTimeStamp: time,
                                decodeTimeStamp: .invalid
                            ),
                            dataRange: 0 ..< sampleSize,
                            flags: .keyframe
                        )
                    )
                    time = time + sampleDuration
                    state = .findingSync
                }
            }
        }
    }

    /// Moves past the next sync word, 0xAC40 or 0xAC41 for frames with a CRC.
    ///
    /// - Returns: Whether one was found.
    private func skipToNextSync(_ data: inout BlockBufferReader) throws -> Bool {
        while data.readableBytes > 0 {
            let byte = try data.readInt(as: UInt8.self)
            guard lastByteWasAC else {
                lastByteWasAC = byte == 0xAC
                continue
            }
            lastByteWasAC = byte == 0xAC
            if byte == 0x40 || byte == 0x41 {
                hasCrc = byte == 0x41
                return true
            }
        }
        return false
    }

    private func parseHeader(output: TrackOutput) throws {
        var bits = BlockBufferBitReader(reader: header)
        let frameInfo = try Ac4Util.parseAc4SyncFrameInfo(&bits)
        if format == nil
            || frameInfo.channelCount != formatFrame?.channelCount
            || frameInfo.sampleRate != formatFrame?.sampleRate {
            var format = AudioFormat()
            format.codec = AudioCodec(.audioAC4)
            format.sampleRate = frameInfo.sampleRate
            format.channelCount = frameInfo.channelCount
            format.id = try formatId.checkNotNil()
            format.containerMimeType = containerMimeType
            format.language = language
            format.roleFlags = roleFlags
            self.format = format
            formatFrame = (frameInfo.channelCount, frameInfo.sampleRate)
            try output.setFormat(AnyFormat(format))
        }
        sampleSize = frameInfo.frameSize
        sampleDuration = CMTime(value: CMTimeValue(frameInfo.sampleCount), timescale: CMTimeScale(frameInfo.sampleRate))
    }
}
