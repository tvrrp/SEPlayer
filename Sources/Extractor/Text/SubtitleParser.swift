//
//  SubtitleParser.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import CoreMedia
import SEPlayerCommon

/// Factory for `SubtitleParser` instances.
public protocol SubtitleParserFactory {
    /// Returns whether the factory is able to instantiate a `SubtitleParser` for the given `Format`.
    ///
    /// - Parameter format: The `Format`.
    /// - Returns: Whether the factory can instantiate a suitable `SubtitleParser`.
    func supportsFormat(_ format: Format) -> Bool

    /// Returns the `Format.CueReplacementBehavior` of the `SubtitleParser` implementation that handles `format`.
    ///
    /// - Returns: The replacement behavior.
    /// - Throws: If `format` is not supported by this factory.
    func getCueReplacementBehavior(format: Format) throws -> Format.CueReplacementBehavior

    /// Creates a `SubtitleParser` for the given `Format`.
    ///
    /// - Returns: The `SubtitleParser` instance.
    /// - Throws: If `format` is not supported by this factory.
    func create(format: Format) throws -> SubtitleParser
}

/// Parses subtitle data into timed `CuesWithTiming` instances.
///
/// Instances are stateful, so samples can be fed in repeated calls to `parse`, and one or more complete
/// `CuesWithTiming` instances will be returned when enough data has been received. Due to this stateful-ness, `reset()`
/// must be called after a seek or similar discontinuity in the source data.
public protocol SubtitleParser {
    /// Parses `data` (and any data stored from previous invocations) and emits any resulting complete `CuesWithTiming`
    /// instances via `output`.
    ///
    /// Any samples not used from `data` will be persisted and used during subsequent calls to this method.
    ///
    /// `CuesWithTiming.startTime` in an emitted instance is derived only from the provided sample data, so has to be
    /// considered together with any relevant `Format.subsampleOffset`. If the provided sample doesn't contain any timing
    /// information then at most one `CuesWithTiming` instance will be emitted, with `CuesWithTiming.startTime` set to
    /// `.invalid`, in which case `Format.subsampleOffset` **must** be `Format.offsetSampleRelative`.
    ///
    /// - Parameters:
    ///   - data: The subtitle data to parse, its readable bytes. This must contain only complete samples. For subtitles
    ///     muxed inside a media container, a sample is usually defined by the container. For subtitles read from a text
    ///     file, a sample is usually the entire contents of the text file.
    ///   - outputOptions: Options to control how instances are emitted to `output`.
    ///   - output: A consumer for `CuesWithTiming` instances emitted by this method. All calls will be made before this
    ///     method returns.
    func parse(
        data: BlockBufferReader,
        outputOptions: SubtitleParserOutputOptions,
        output: (CuesWithTiming) throws -> Void
    ) throws

    /// Clears any data stored inside this parser from previous `parse` calls.
    ///
    /// This must be called after a seek or other similar discontinuity in the source data.
    ///
    /// The default implementation is a no-op.
    func reset()

    /// Returns the `Format.CueReplacementBehavior` for consecutive `CuesWithTiming` emitted by this implementation.
    ///
    /// A given instance must always return the same value from this method.
    func getCueReplacementBehavior() -> Format.CueReplacementBehavior
}

public extension SubtitleParser {
    func reset() {}
}

/// Options to control the output behavior of `SubtitleParser` methods that emit their output incrementally using a
/// closure provided by the caller.
public struct SubtitleParserOutputOptions {
    /// Cues after this time (inclusive) will be emitted first. Cues before this time might be emitted later, depending
    /// on `outputAllCues`. Can be `.invalid` to emit all cues.
    public let startTime: CMTime

    /// Whether to eventually emit all cues, or only those after `startTime`. Ignored if `startTime` is not set.
    public let outputAllCues: Bool

    private init(startTime: CMTime, outputAllCues: Bool) {
        self.startTime = startTime
        self.outputAllCues = outputAllCues
    }

    /// Output all `CuesWithTiming` instances.
    public static func allCues() -> Self {
        SubtitleParserOutputOptions(startTime: .invalid, outputAllCues: false)
    }

    /// Only output `CuesWithTiming` instances where `CuesWithTiming.startTime` is at least `startTime`.
    ///
    /// The order in which `CuesWithTiming` instances are emitted is not defined.
    public static func onlyCuesAfter(startTime: CMTime) -> Self {
        SubtitleParserOutputOptions(startTime: startTime, outputAllCues: false)
    }

    /// Output `CuesWithTiming` where `CuesWithTiming.startTime` is at least `startTime`, followed by the remaining
    /// `CuesWithTiming` instances.
    ///
    /// Beyond this, the order in which `CuesWithTiming` instances are emitted is not defined.
    public static func cuesAfterThenRemainingCuesBefore(startTime: CMTime) -> Self {
        SubtitleParserOutputOptions(startTime: startTime, outputAllCues: true)
    }
}

/// Initialization data of the samples a subtitle parser outputs: each sample holds cues that `CueEncoder` encoded.
struct CuesInitializationData: Format.InitializationData {
    /// `sepc`.
    static let mediaSubType = CMFormatDescription.MediaSubType(rawValue: 0x73657063)

    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        try CMFormatDescription(mediaType: .text, mediaSubType: Self.mediaSubType)
    }
}

public extension Format {
    /// The format of the samples a subtitle parser outputs for subtitles of `self`.
    func cuesFormat(cueReplacementBehavior: CueReplacementBehavior) -> Format.Builder {
        buildUpon()
            .setSampleMimeType(.applicationSEPlayerCues)
            .setCodecs(sampleMimeType?.rawValue)
            .setInitializationData(CuesInitializationData())
            .setCueReplacementBehavior(cueReplacementBehavior)
    }
}
