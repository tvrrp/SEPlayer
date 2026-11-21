//
//  IcyDataReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Reads an ICY stream without its metadata: a block of metadata follows every `metadataInterval` bytes of the
/// stream, a length byte (in 16-byte units) then the metadata.
///
/// The positions it reads are those of the stream without the metadata. The blocks are found as the reads go
/// forward, and each is reported once, in order.
final class IcyDataReader: DataReader {
    /// A run of stream bytes: where it is in the stream without metadata, and in the upstream data.
    private struct Segment {
        let start: Int
        let upstreamStart: Int
        let length: Int

        var end: Int { start + length }
    }

    private let upstream: DataReader
    private let metadataInterval: Int
    private let onMetadata: (CMBlockBuffer) -> Void

    private var segments: [Segment] = []
    /// Where the stream without metadata found so far ends.
    private var mappedEnd: Int
    /// Where the next metadata block starts in the upstream data.
    private var nextMetadataPosition: Int
    private var upstreamEnded = false

    var isolation: any Actor { upstream.isolation }

    /// - Parameters:
    ///   - start: The position the upstream data starts at: the first byte of the response.
    ///   - onMetadata: Called with each metadata block that isn't empty.
    init(upstream: DataReader, start: Int, metadataInterval: Int, onMetadata: @escaping (CMBlockBuffer) -> Void) {
        self.upstream = upstream
        self.metadataInterval = metadataInterval
        self.onMetadata = onMetadata
        segments = [Segment(start: start, upstreamStart: start, length: metadataInterval)]
        mappedEnd = start + metadataInterval
        nextMetadataPosition = start + metadataInterval
    }

    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard !range.isEmpty else { return try CMBlockBuffer() }
        try await mapStream(upTo: range.upperBound, isolation)

        let result = try CMBlockBuffer()
        var position = range.lowerBound
        while position < range.upperBound,
              let segment = segments.last(where: { $0.start <= position && position < $0.end }) {
            let upstreamPosition = segment.upstreamStart + (position - segment.start)
            let length = min(range.upperBound, segment.end) - position
            let upstreamRange = upstreamPosition ..< upstreamPosition + length
            guard let buffer = try await upstream.read(range: upstreamRange, isolation), !buffer.isEmpty else {
                break
            }
            try result.append(bufferReference: buffer)
            position += buffer.dataLength
            // A short read: the rest comes with the next one.
            if buffer.dataLength < length { break }
        }
        return result.isEmpty && position == range.lowerBound ? nil : result
    }

    /// Finds the metadata blocks up to `position` of the stream without metadata.
    private func mapStream(upTo position: Int, _ isolation: isolated any Actor) async throws {
        while !upstreamEnded, mappedEnd < position {
            guard let lengthBuffer = try await readUpstream(at: nextMetadataPosition, length: 1, isolation) else {
                upstreamEnded = true
                return
            }
            let lengthByte = try BlockBufferReader(lengthBuffer).getInt(at: 0, as: UInt8.self)
            let metadataLength = Int(lengthByte) * Self.metadataLengthUnit
            if metadataLength > 0 {
                let metadataPosition = nextMetadataPosition + 1
                guard let metadata = try await readUpstream(at: metadataPosition, length: metadataLength, isolation) else {
                    upstreamEnded = true
                    return
                }
                onMetadata(metadata)
            }
            let segmentStart = nextMetadataPosition + 1 + metadataLength
            segments.append(Segment(start: mappedEnd, upstreamStart: segmentStart, length: metadataInterval))
            mappedEnd += metadataInterval
            nextMetadataPosition = segmentStart + metadataInterval
            // Only the segments a read may go back to are kept.
            if segments.count > Self.maxSegments {
                segments.removeFirst(segments.count - Self.maxSegments)
            }
        }
    }

    /// `length` upstream bytes at `position`, or `nil` if the data ends before them.
    private func readUpstream(
        at position: Int,
        length: Int,
        _ isolation: isolated any Actor
    ) async throws -> CMBlockBuffer? {
        let result = try CMBlockBuffer()
        let end = position + length
        while result.dataLength < length {
            let range = position + result.dataLength ..< end
            guard let buffer = try await upstream.read(range: range, isolation), !buffer.isEmpty else {
                return nil
            }
            try result.append(bufferReference: buffer)
        }
        return result
    }
}

private extension IcyDataReader {
    /// Enough for the extractors' peeks, which go back no further than a few frames.
    static let maxSegments = 64
    /// The length byte of a metadata block counts units of this many bytes.
    static let metadataLengthUnit = 16
}
