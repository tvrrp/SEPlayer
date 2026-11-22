//
//  HlsExtractorFactory.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.hls.HlsExtractorFactory
//    androidx.media3.exoplayer.hls.DefaultHlsExtractorFactory
//    androidx.media3.exoplayer.hls.TimestampAdjusterProvider
//  Copyright (C) 2016, 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Extractor
import Foundation
import SEPlayerCommon

/// Provides a ``TimestampAdjuster`` for every discontinuity sequence: segments in one discontinuity, of any
/// rendition, share a timeline.
final class TimestampAdjusterProvider: @unchecked Sendable {
    private let lock = UnfairLock()
    private var adjusters: [Int: TimestampAdjuster] = [:] // guarded by lock

    /// The adjuster of the discontinuity sequence.
    func adjuster(discontinuitySequence: Int) -> TimestampAdjuster {
        lock.withLock {
            if let adjuster = adjusters[discontinuitySequence] { return adjuster }
            let adjuster = TimestampAdjuster(mode: .shared)
            adjusters[discontinuitySequence] = adjuster
            return adjuster
        }
    }

    /// Resets the provider.
    func reset() {
        lock.withLock { adjusters.removeAll() }
    }
}

/// The extractor of an HLS media chunk, which following chunks may reuse.
public final class HlsMediaChunkExtractor: @unchecked Sendable {
    public let extractor: any Extractor
    /// Whether a following chunk of the same rendition and discontinuity can go on with this extractor. It keeps
    /// what it learned from the initialization section and the earlier segments.
    public let isReusable: Bool
    /// Whether the extractor got its output.
    var isInitialized = false

    public init(extractor: any Extractor, isReusable: Bool) {
        self.extractor = extractor
        self.isReusable = isReusable
    }
}

/// Creates extractors for HLS media chunks.
public protocol HlsExtractorFactory {
    /// Creates an extractor for the media chunk at `url`, sniffing `input` to find the container.
    ///
    /// - Parameters:
    ///   - format: The format of the rendition the chunk belongs to.
    ///   - closedCaptionFormats: The closed captions in the video, as the playlist declares them; `nil` if it doesn't.
    ///   - timestampSession: Maps sample times to the discontinuity's timeline.
    func createExtractor(
        url: URL,
        format: AnyFormat,
        closedCaptionFormats: [TextFormat]?,
        timestampSession: TimestampAdjuster.Session,
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> HlsMediaChunkExtractor
}

/// Creates extractors for MPEG-TS, fragmented MP4, packed audio (ADTS, AC-3, AC-4, MP3) and WebVTT segments.
public struct DefaultHlsExtractorFactory: HlsExtractorFactory {
    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory

    /// CC1, the closed captions a video without a declaration may have.
    private static let defaultClosedCaptionFormat = TextFormat {
        $0.codec = TextCodec(.applicationCEA608, \.cea608) { $0.channel = 1 }
        $0.label = "CC1"
    }

    /// - Parameters:
    ///   - queue: The queue extractors run on.
    ///   - subtitleParserFactory: Parses the subtitles of subtitle renditions and in segments into cues.
    public init(queue: Queue, subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory()) {
        self.queue = queue
        self.subtitleParserFactory = subtitleParserFactory
    }

    public func createExtractor(
        url: URL,
        format: AnyFormat,
        closedCaptionFormats: [TextFormat]?,
        timestampSession: TimestampAdjuster.Session,
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> HlsMediaChunkExtractor {
        // The file type the url or the format suggests goes first; the others are tried after it.
        let inferred = FileType(url: url) ?? inferFileType(format: format)
        var fileTypes = Self.fileTypes
        if let inferred, let index = fileTypes.firstIndex(of: inferred) {
            fileTypes.remove(at: index)
            fileTypes.insert(inferred, at: 0)
        }

        // Packed audio starts with an ID3 tag that gives the MPEG-TS time of its first sample.
        let id3Timestamp = try await Id3Peeker.peekTransportStreamTimestamp(input: input, isolation)
        // Adjusted only if an extractor of packed audio is made: adjusting it sets the timeline of the discontinuity.
        lazy var packedAudioStartTime = id3Timestamp.map { timestampSession.adjustTS(pts33: $0, dts33: nil).pts }
            ?? timestampSession.desiredFirstSampleTime
            ?? .zero

        var sniffFailures: [any SniffFailure] = []
        for fileType in fileTypes {
            let extractor = try makeExtractor(
                fileType,
                format: format,
                closedCaptionFormats: closedCaptionFormats,
                timestampSession: timestampSession,
                firstSampleTime: fileType.isPackedAudio ? packedAudioStartTime : .zero
            )
            defer { input.resetPeekPosition(isolation) }
            do {
                if try await extractor.sniff(input: input, isolation) {
                    SELogger.debug(.sniffing, "\(url.lastPathComponent) is \(fileType): \(type(of: extractor))")
                    return HlsMediaChunkExtractor(extractor: extractor, isReusable: fileType.isReusable)
                }
                sniffFailures.append(contentsOf: extractor.getSniffFailureDetails(isolation))
            } catch is EndOfFileError {
                continue
            }
        }

        // Too little to sniff, as the tables at the start of an MPEG-TS file that a keyframe of an I-frame playlist
        // reads first: the extractor of the type the url or the format suggest reads it.
        if let inferred {
            SELogger.debug(
                .sniffing,
                "\(url.lastPathComponent) is read as \(inferred), the type it suggests: \(sniffFailures)"
            )
            let extractor = try makeExtractor(
                inferred,
                format: format,
                closedCaptionFormats: closedCaptionFormats,
                timestampSession: timestampSession,
                firstSampleTime: inferred.isPackedAudio ? packedAudioStartTime : .zero
            )
            return HlsMediaChunkExtractor(extractor: extractor, isReusable: inferred.isReusable)
        }

        SELogger.error(.sniffing, "No extractor reads \(url.lastPathComponent): \(sniffFailures)")
        throw UnrecognizedInputFormatError(
            message: "None of the available extractors could read the segment.",
            url: url,
            sniffFailures: sniffFailures
        )
    }

    private func makeExtractor(
        _ fileType: FileType,
        format: AnyFormat,
        closedCaptionFormats: [TextFormat]?,
        timestampSession: TimestampAdjuster.Session,
        firstSampleTime: CMTime
    ) throws -> any Extractor {
        switch fileType {
        case .mp4:
            // Only the captions the playlist declares: unlike in MPEG-TS, nothing in the file would show them.
            return FragmentedMp4Extractor(
                queue: queue,
                subtitleParserFactory: subtitleParserFactory,
                timestampSession: timestampSession,
                closedCaptionFormats: closedCaptionFormats ?? []
            )
        case .webvtt:
            return WebvttExtractor(
                queue: queue,
                language: format.language,
                timestampSession: timestampSession,
                subtitleParserFactory: subtitleParserFactory
            )
        case .ts:
            // The captions the playlist declares are the ones there are; without a declaration, CC1 may be there.
            var flags: DefaultTsPayloadReaderFactory.Flags = closedCaptionFormats == nil ? [] : .overrideCaptionDescriptors
            // SCTE-35 cues belong with date ranges and ads, which aren't read.
            flags.insert(.ignoreSpliceInfoStream)
            // Segments may declare AAC and H.264 streams that aren't there: those the codecs leave out are ignored.
            let codecs = Codecs.split(format.codecs).compactMap(Codecs.mediaMimeType(forCodec:))
            if !codecs.isEmpty {
                if !codecs.contains(.audioAAC) { flags.insert(.ignoreAACStream) }
                if !codecs.contains(.videoH264) { flags.insert(.ignoreH264Stream) }
            }
            return try TsExtractor(
                queue: queue,
                mode: .hls,
                subtitleParserFactory: subtitleParserFactory,
                session: timestampSession,
                payloadReaderFactory: DefaultTsPayloadReaderFactory(
                    flags: flags,
                    closedCaptionFormats: closedCaptionFormats ?? [Self.defaultClosedCaptionFormat]
                )
            )
        case .adts:
            return try AdtsExtractor(firstSampleTime: firstSampleTime)
        case .ac3:
            return try Ac3Extractor(firstSampleTime: firstSampleTime)
        case .ac4:
            return try Ac4Extractor(firstSampleTime: firstSampleTime)
        case .mp3:
            return Mp3Extractor(queue: queue, forcedFirstSampleTime: firstSampleTime)
        }
    }

    /// The file type the format of a rendition suggests.
    private func inferFileType(format: AnyFormat) -> FileType? {
        // The format of a subtitle rendition may already be that of its parsed cues, with the original type in its
        // codecs.
        if format.codecs == MimeTypes.textVTT.rawValue { return .webvtt }
        // AAC in a container isn't packed audio.
        if format.sampleMimeType == .audioAAC, format.containerMimeType != nil {
            return FileType(mimeType: format.containerMimeType)
        }
        return FileType(mimeType: format.sampleMimeType) ?? FileType(mimeType: format.containerMimeType)
    }
}

private extension DefaultHlsExtractorFactory {
    /// The file types in the order they are sniffed when neither the url nor the format tells.
    static let fileTypes: [FileType] = [.mp4, .webvtt, .ts, .adts, .ac3, .ac4, .mp3]
}

private extension FileType {
    /// Whether segments are elementary audio streams, whose times come from an ID3 tag.
    var isPackedAudio: Bool {
        switch self {
        case .adts,
             .ac3,
             .ac4,
             .mp3: true
        default: false
        }
    }

    /// Whether the extractor of a segment reads the next one too. A WebVTT segment is read whole, with its own
    /// header; packed audio has its own times.
    var isReusable: Bool { self != .webvtt && !isPackedAudio }
}
