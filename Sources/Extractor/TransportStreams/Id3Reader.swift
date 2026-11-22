//
//  Id3Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.Id3Reader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Parses ID3 data and extracts individual text information frames.
final class Id3Reader: ElementaryStreamReader {
    private let containerMimeType: MimeTypes
    /// Where the tags are copied to.
    private let sampleMemory = SampleMemory(blockSize: 16 * 1024) // 16 KB

    private var output: TrackOutput?
    private var id3Header: BlockBufferReader
    private var writingSample = false
    private var sampleTime = CMTime.invalid
    private var sampleSize = 0
    private var sampleBytesRead = 0

    init(containerMimeType: MimeTypes) throws {
        self.containerMimeType = containerMimeType
        id3Header = try BlockBufferReader()
    }

    func seek() {
        writingSample = false
        sampleTime = .invalid
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .metadata)
        let formatId = try idGenerator.getFormatId()
        let format = MetadataFormat {
            $0.id = formatId
            $0.containerMimeType = containerMimeType
            $0.codec = .applicationID3
        }
        try trackOutput.setFormat(AnyFormat(format))
        self.output = trackOutput
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        // A tag starts with an aligned packet.
        guard flags.contains(.dataAlignment) else { return }
        writingSample = true
        sampleTime = pesTime
        sampleSize = 0
        sampleBytesRead = 0
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        guard writingSample else {
            data.moveReaderIndex(forwardBy: data.readableBytes)
            return
        }

        if sampleBytesRead < Id3Decoder.headerLength {
            if sampleBytesRead == 0 { try id3Header.clear() }
            // The header is written with the rest of the tag: it is looked at, not taken.
            var headerSource = data
            if try id3Header.fill(from: &headerSource, upTo: Id3Decoder.headerLength) {
                guard let framesSize = Id3Decoder.framesSize(header: id3Header) else {
                    SELogger.warning(.metadata, "Discarding invalid ID3 tag")
                    writingSample = false
                    data.moveReaderIndex(forwardBy: data.readableBytes)
                    return
                }
                sampleSize = Id3Decoder.headerLength + framesSize
            }
        }

        let bytesToWrite = min(data.readableBytes, max(sampleSize, Id3Decoder.headerLength) - sampleBytesRead)
        try output.sampleData(data: sampleMemory.copy(from: &data, length: bytesToWrite))
        sampleBytesRead += bytesToWrite
        // The rest of the packet isn't part of the tag.
        data.moveReaderIndex(forwardBy: data.readableBytes)
    }

    func packetFinished() throws {
        let output = try output.checkNotNil()
        guard writingSample, sampleSize != 0, sampleBytesRead == sampleSize else {
            return
        }
        try checkArgument(sampleTime.isNumeric)
        try output.sampleMetadata(
            SampleProperties(
                timingInfo: CMSampleTimingInfo(
                    duration: .zero,
                    presentationTimeStamp: sampleTime,
                    decodeTimeStamp: .invalid
                ),
                dataRange: 0 ..< sampleSize,
                flags: .keyframe
            )
        )
        writingSample = false
    }
}
