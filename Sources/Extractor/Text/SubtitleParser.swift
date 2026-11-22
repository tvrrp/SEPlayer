//
//  SubtitleParser.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.SubtitleParser
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Factory for `SubtitleParser` instances.
public protocol SubtitleParserFactory {
    /// Returns whether the factory is able to instantiate a `SubtitleParser` for the given format.
    ///
    /// - Parameter format: The format of the subtitles.
    /// - Returns: Whether the factory can instantiate a suitable `SubtitleParser`.
    func supportsFormat(_ format: TextFormat) -> Bool

    /// Returns the `CueReplacementBehavior` of the `SubtitleParser` implementation that handles `format`.
    ///
    /// - Returns: The replacement behavior.
    /// - Throws: If `format` is not supported by this factory.
    func getCueReplacementBehavior(format: TextFormat) throws -> CueReplacementBehavior

    /// Creates a `SubtitleParser` for the given format.
    ///
    /// - Returns: The `SubtitleParser` instance.
    /// - Throws: If `format` is not supported by this factory.
    func create(format: TextFormat) throws -> SubtitleParser
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
    /// considered together with any relevant `subsampleOffset` of the format. If the provided sample doesn't contain any timing
    /// information then at most one `CuesWithTiming` instance will be emitted, with `CuesWithTiming.startTime` set to
    /// `.invalid`, in which case the `subsampleOffset` of the format **must** be `nil`.
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

    /// Returns the `CueReplacementBehavior` for consecutive `CuesWithTiming` emitted by this implementation.
    ///
    /// A given instance must always return the same value from this method.
    func getCueReplacementBehavior() -> CueReplacementBehavior
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

public extension Format where Scope == FormatAttributes.Text {
    /// The format of the samples a subtitle parser outputs for subtitles of `self`: each sample holds cues that
    /// `CueEncoder` encoded. The codec keeps the attributes of the source, such as the channel of captions.
    func cuesFormat(cueReplacementBehavior: CueReplacementBehavior) -> TextFormat {
        var codec = self.codec ?? TextCodec(.applicationSEPlayerCues)
        codec.cues.source = self.codec?.mimeType
        codec.mimeType = .applicationSEPlayerCues
        return with {
            $0.codec = codec
            $0.cueReplacementBehavior = cueReplacementBehavior
        }
    }
}
