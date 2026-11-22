//
//  Id3Peeker.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.Id3Peeker
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// Peeks the ID3 tags at the start of an input.
public enum Id3Peeker {
    /// The owner of the PRIV frame that HLS packed audio segments start with: the MPEG-TS time of their first sample.
    public static let transportStreamTimestampOwner = "com.apple.streaming.transportStreamTimestamp"

    /// Decodes the first of the ID3 tags at the peek position, and moves the peek position past all of them.
    ///
    /// - Parameter maxTagPeekBytes: How many bytes of junk may come before a tag; it isn't looked for past an MPEG
    ///   audio frame header.
    /// - Returns: The metadata of the first tag, or `nil` if there is none.
    public static func peekId3Data(
        input: any ExtractorInput,
        framePredicate: Id3Decoder.FramePredicate?,
        maxTagPeekBytes: Int = 0,
        _ isolation: isolated any Actor
    ) async throws -> Metadata? {
        var peekedId3Bytes = 0
        var metadata: Metadata?
        while let (header, skippedBytes) = try await peekId3Header(input: input, maxTagPeekBytes: maxTagPeekBytes, isolation) {
            let framesLength = Id3Decoder.framesSize(header: header) ?? 0
            if metadata == nil, let frames = try await input.peekReader(length: framesLength, isolation) {
                try header.extend(with: frames, permitEmptyReference: true)
                metadata = Id3Decoder(framePredicate: framePredicate).decode(header)
            } else {
                try input.advancePeekPosition(length: framesLength, isolation)
            }
            peekedId3Bytes += skippedBytes + Id3Decoder.headerLength + framesLength
        }
        input.resetPeekPosition(isolation)
        try input.advancePeekPosition(length: peekedId3Bytes, isolation)
        return metadata
    }

    /// The MPEG-TS time of the `com.apple.streaming.transportStreamTimestamp` PRIV frame of the ID3 tag at the start
    /// of the input, in 90 kHz ticks: 33 bits. Leaves the peek position at the start.
    public static func peekTransportStreamTimestamp(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> Int64? {
        input.resetPeekPosition(isolation)
        defer { input.resetPeekPosition(isolation) }
        guard let tag = try await input.peekReader(length: Id3Decoder.headerLength, isolation),
              let size = Id3Decoder.framesSize(header: tag),
              let frames = try await input.peekReader(length: size, isolation) else {
            return nil
        }
        try tag.extend(with: frames, permitEmptyReference: true)
        let privFrames = Id3Decoder().decode(tag)?.entries.compactMap { $0 as? PrivFrame } ?? []
        guard let frame = privFrames.first(where: { $0.owner == transportStreamTimestampOwner }),
              frame.privateData.count >= 8 else {
            return nil
        }
        let timestamp = frame.privateData.prefix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        // The top 31 bits should be zeros; they are cleared in case the provider left them set.
        return timestamp & 0x1_FFFF_FFFF
    }

    /// The header of the next ID3 tag, and the junk bytes before it.
    private static func peekId3Header(
        input: any ExtractorInput,
        maxTagPeekBytes: Int,
        _ isolation: isolated any Actor
    ) async throws -> (header: BlockBufferReader, skippedBytes: Int)? {
        let startPosition = input.getPeekPosition(isolation)
        var skippedBytes = 0
        while let header = try await input.peekReader(length: Id3Decoder.headerLength, isolation) {
            if header.readableBytesView.starts(with: Id3Decoder.tagIdentifier) {
                return (header, skippedBytes)
            }
            // A tag isn't looked for past a frame of MPEG audio.
            let frameHeader = try Int(header.getInt(at: 0, as: UInt32.self))
            if MpegAudioUtil.frameSize(headerData: frameHeader) != nil || skippedBytes >= maxTagPeekBytes {
                return nil
            }
            skippedBytes += 1
            input.resetPeekPosition(isolation)
            try input.advancePeekPosition(length: startPosition - input.getPosition(isolation) + skippedBytes, isolation)
        }
        return nil
    }
}
