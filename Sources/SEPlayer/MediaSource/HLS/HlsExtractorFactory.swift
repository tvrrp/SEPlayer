//
//  HlsExtractorFactory.swift
//  SEPlayer
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
final class HlsMediaChunkExtractor: @unchecked Sendable {
    let extractor: any Extractor
    /// Whether a following chunk of the same rendition and discontinuity can go on with this extractor. It keeps
    /// what it learned from the initialization section and the earlier segments.
    let isReusable: Bool
    /// Whether the extractor got its output.
    var isInitialized = false

    init(extractor: any Extractor, isReusable: Bool) {
        self.extractor = extractor
        self.isReusable = isReusable
    }
}

/// Creates extractors for HLS media chunks.
protocol HlsExtractorFactory {
    /// Creates an extractor for the media chunk at `url`, sniffing `input` to find the container.
    ///
    /// - Parameters:
    ///   - format: The format of the rendition the chunk belongs to.
    ///   - closedCaptionFormats: The closed captions in the video, as the playlist declares them; `nil` if it doesn't.
    ///   - timestampSession: Maps sample times to the discontinuity's timeline.
    func createExtractor(
        url: URL,
        format: Format,
        closedCaptionFormats: [Format]?,
        timestampSession: TimestampAdjuster.Session,
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> HlsMediaChunkExtractor
}

/// Creates extractors for MPEG-TS, fragmented MP4 and WebVTT segments.
struct DefaultHlsExtractorFactory: HlsExtractorFactory {
    private enum FileType: CaseIterable {
        case ts
        case fragmentedMp4
        case webvtt
    }

    private let queue: Queue
    private let subtitleParserFactory: SubtitleParserFactory

    /// CC1, the closed captions a video without a declaration may have.
    private static let defaultClosedCaptionFormat = Format.Builder()
        .setSampleMimeType(.applicationCEA608)
        .setAccessibilityChannel(1)
        .setLabel("CC1")
        .build()

    /// - Parameter queue: The queue extractors run on.
    init(queue: Queue, subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory()) {
        self.queue = queue
        self.subtitleParserFactory = subtitleParserFactory
    }

    func createExtractor(
        url: URL,
        format: Format,
        closedCaptionFormats: [Format]?,
        timestampSession: TimestampAdjuster.Session,
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> HlsMediaChunkExtractor {
        // The file type the url suggests goes first; the others are tried after it.
        var fileTypes = FileType.allCases
        let inferred = inferFileType(url: url, format: format)
        if let inferred, let index = fileTypes.firstIndex(of: inferred) {
            fileTypes.remove(at: index)
            fileTypes.insert(inferred, at: 0)
        }

        var sniffFailures: [any SniffFailure] = []
        for fileType in fileTypes {
            let extractor = try makeExtractor(
                fileType,
                format: format,
                closedCaptionFormats: closedCaptionFormats,
                timestampSession: timestampSession
            )
            defer { input.resetPeekPosition(isolation) }
            do {
                if try await extractor.sniff(input: input, isolation) {
                    SELogger.debug(.sniffing, "\(url.lastPathComponent) is \(fileType): \(type(of: extractor))")
                    // A WebVTT segment is read whole, with its own header.
                    return HlsMediaChunkExtractor(extractor: extractor, isReusable: fileType != .webvtt)
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
                timestampSession: timestampSession
            )
            return HlsMediaChunkExtractor(extractor: extractor, isReusable: inferred != .webvtt)
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
        format: Format,
        closedCaptionFormats: [Format]?,
        timestampSession: TimestampAdjuster.Session
    ) throws -> any Extractor {
        switch fileType {
        case .ts:
            // The captions the playlist declares are the ones there are; without a declaration, CC1 may be there.
            var flags: DefaultTsPayloadReaderFactory.Flags = closedCaptionFormats == nil ? [] : .overrideCaptionDescriptors
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
        case .fragmentedMp4:
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
        }
    }

    private func inferFileType(url: URL, format: Format) -> FileType? {
        switch url.pathExtension.lowercased() {
        case "ts", "tsa", "tsv", "m2ts", "mts":
            return .ts
        case "mp4", "m4s", "m4a", "m4v", "cmfv", "cmfa", "cmft":
            return .fragmentedMp4
        case "vtt", "webvtt":
            return .webvtt
        default:
            // The format of a subtitle rendition may already be that of its parsed cues, with the original type in
            // its codecs.
            if format.sampleMimeType == .textVTT || format.codecs == MimeTypes.textVTT.rawValue {
                return .webvtt
            }
            switch format.containerMimeType {
            case .videoMP2T: return .ts
            case .videoMP4, .audioMP4, .applicationMP4: return .fragmentedMp4
            default: return nil
            }
        }
    }
}
