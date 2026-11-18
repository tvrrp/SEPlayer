//
//  WebvttExtractor.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Extracts the WebVTT segment of an HLS subtitle rendition as one sample, timed on the timeline of its discontinuity.
///
/// The `X-TIMESTAMP-MAP` header maps the times of the cues to the MPEG-2 timestamps of the media segments; without
/// it, cue times are taken as MPEG-2 timestamps. The cues are parsed during extraction.
public final class WebvttExtractor: Extractor {
    private let queue: Queue
    private let language: String?
    private let timestampSession: TimestampAdjuster.Session
    private let subtitleParserFactory: SubtitleParserFactory

    private var output: ExtractorOutput?
    private var sampleData = Data()
    private var lastSniffFailures: [any SniffFailure] = []

    public init(
        queue: Queue,
        language: String?,
        timestampSession: TimestampAdjuster.Session,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory()
    ) {
        self.queue = queue
        self.language = language
        self.timestampSession = timestampSession
        self.subtitleParserFactory = subtitleParserFactory
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        assert(queue.isCurrent())
        // The header without a byte order mark, then with one.
        for length in [Int.webvttHeaderMinLength, Int.webvttHeaderMaxLength] {
            let (buffer, isEndOfInput) = try await input.peekFully(length: length, allowEndOfInput: true, isolation)
            input.resetPeekPosition(isolation)
            guard !isEndOfInput else {
                continue
            }

            let headerBytes = try BlockBufferReader(buffer).getData(at: 0, length: buffer.dataLength)
            if let header = String(data: headerBytes, encoding: .utf8), WebvttParserUtil.isWebvttHeaderLine(header) {
                return true
            }
        }
        return false
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        assert(queue.isCurrent())
        let output = SubtitleTranscodingExtractorOutput(delegate: output, subtitleParserFactory: subtitleParserFactory)
        self.output = output
        output.seekMap(seekMap: Unseekable(duration: .invalid))
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        let length = input.getLength(isolation).map { $0 - input.getPosition(isolation) } ?? .webvttReadLength
        if length > 0 {
            let (buffer, isEndOfInput) = try await input.readFully(length: length, allowEndOfInput: true, isolation)
            if !buffer.isEmpty {
                sampleData.append(try BlockBufferReader(buffer).getData(at: 0, length: buffer.dataLength))
            }
            let reachedLength = input.getLength(isolation).map { input.getPosition(isolation) >= $0 } ?? false
            guard isEndOfInput || reachedLength else { return .continueRead }
        }
        try await processSample(isolation)
        return .endOfInput
    }

    /// A segment is read in one piece, from its start.
    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        sampleData = Data()
    }

    public func release(_ isolation: isolated any Actor) {
        sampleData = Data()
    }

    private func processSample(_ isolation: isolated any Actor) async throws {
        var reader = try WebvttLineReader(data: sampleData)
        try WebvttParserUtil.validateWebvttHeaderLine(&reader)

        var vttTimestamp = CMTime.zero
        var tsTimestamp = CMTime.zero
        while let line = reader.readLine(), !line.isEmpty {
            guard line.hasPrefix("X-TIMESTAMP-MAP") else { continue }
            guard let local = Self.value(of: "LOCAL:", in: line) else {
                throw ParserError.createForMalformedContainer(message: "X-TIMESTAMP-MAP doesn't contain local timestamp: \(line)")
            }
            guard let media = Self.value(of: "MPEGTS:", in: line), let mpegTimestamp = Int64(media) else {
                throw ParserError.createForMalformedContainer(message: "X-TIMESTAMP-MAP doesn't contain media timestamp: \(line)")
            }
            vttTimestamp = try WebvttParserUtil.parseTimestamp(local)
            tsTimestamp = CMTime(value: mpegTimestamp, timescale: Self.tsTimescale)
        }

        guard let cueHeader = WebvttParserUtil.findNextCueHeader(&reader) else {
            // A segment without cues still declares the track.
            SELogger.verbose(.subtitles, "WebVTT segment without cues")
            try await buildTrackOutput(subsampleOffset: .zero, isolation)
            return
        }

        let firstCueTime = try WebvttParserUtil.parseTimestamp(cueHeader.startTimestamp)
        let cueTimeAsTs = firstCueTime + tsTimestamp - vttTimestamp
        let wrappedTicks = cueTimeAsTs.convertScale(Self.tsTimescale, method: .roundTowardNegativeInfinity).value
            & Self.ptsMask
        let sampleTime = timestampSession.adjustTS(pts33: wrappedTicks, dts33: nil).pts
        let subsampleOffset = sampleTime - firstCueTime
        SELogger.debug(.subtitles, "WebVTT segment: first cue at \(firstCueTime.seconds), plays at \(sampleTime.seconds)")

        let trackOutput = try await buildTrackOutput(subsampleOffset: subsampleOffset, isolation)
        let blockBuffer = try makeBlockBuffer(copying: [UInt8](sampleData))
        try trackOutput.sampleData(data: blockBuffer)
        try trackOutput.sampleMetadata(
            time: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: sampleTime, decodeTimeStamp: .invalid),
            flags: .keyframe,
            range: 0..<sampleData.count
        )
    }

    @discardableResult
    private func buildTrackOutput(subsampleOffset: CMTime, _ isolation: isolated any Actor) async throws -> TrackOutput {
        guard let output else { throw UnexpectedStateError() }
        let trackOutput = try output.track(for: 0, trackType: .text)
        let format = Format.Builder()
            .setSampleMimeType(.textVTT)
            .setLanguage(language)
            .setSubsampleOffset(subsampleOffset)
            .build()
        try trackOutput.setFormat(format)
        output.endTracks()
        return trackOutput
    }

    /// The value after `key` in an `X-TIMESTAMP-MAP` line, up to the next comma.
    private static func value(of key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let value = line[range.upperBound...].prefix { $0 != "," }
        return value.isEmpty ? nil : String(value)
    }

    private static let tsTimescale: CMTimeScale = 90_000
    private static let ptsMask: Int64 = (1 << 33) - 1
}

private extension Int {
    /// The length of `WEBVTT`.
    static let webvttHeaderMinLength = 6
    /// The length of `WEBVTT` after a UTF-8 byte order mark.
    static let webvttHeaderMaxLength = 3 + 6
    /// How much of an input of unknown length is read at a time.
    static let webvttReadLength = 1024
}
