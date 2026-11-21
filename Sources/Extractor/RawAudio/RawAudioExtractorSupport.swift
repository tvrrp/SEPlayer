//
//  RawAudioExtractorSupport.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Helpers of the extractors of raw audio streams: ADTS, AC-3, AC-4.
enum RawAudioExtractorSupport {
    /// The bytes a sniff looks through for frames.
    static let maxSniffBytes = 8 * 1024 // 8 KB

    /// Moves the peek position past the ID3 tags at the start of the input.
    ///
    /// - Returns: The position of the first byte after them.
    static func peekPastId3Tags(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Int {
        input.resetPeekPosition(isolation)
        var startPosition = 0
        while let header = try await input.peekReader(length: Id3Decoder.headerLength, isolation),
              let length = Id3Decoder.framesSize(header: header) {
            startPosition += Id3Decoder.headerLength + length
            try input.advancePeekPosition(length: length, isolation)
        }
        input.resetPeekPosition(isolation)
        try input.advancePeekPosition(length: startPosition, isolation)
        return startPosition
    }

    /// Reads up to `length` bytes, or `nil` at the end of the input.
    static func read(
        input: any ExtractorInput,
        length: Int,
        _ isolation: isolated any Actor
    ) async throws -> BlockBufferReader? {
        let buffer = try await input.read(length: length, isolation)
        input.resetPeekPosition(isolation)
        guard buffer.dataLength > 0 else { return nil }
        return BlockBufferReader(buffer)
    }
}
