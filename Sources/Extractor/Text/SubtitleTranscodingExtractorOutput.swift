//
//  SubtitleTranscodingExtractorOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.SubtitleTranscodingExtractorOutput
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// An ``ExtractorOutput`` that parses the subtitles of its text tracks into cues, as the text renderer reads them, with
/// a ``SubtitleParserFactory``. Tracks of formats the factory doesn't support go on unchanged.
public final class SubtitleTranscodingExtractorOutput: ExtractorOutput {
    private let delegate: ExtractorOutput
    private let subtitleParserFactory: SubtitleParserFactory
    private var textTrackOutputs: [Int: SubtitleTranscodingTrackOutput]

    private var hasNonTextTracks = false

    public init(delegate: ExtractorOutput, subtitleParserFactory: SubtitleParserFactory) {
        self.delegate = delegate
        self.subtitleParserFactory = subtitleParserFactory
        self.textTrackOutputs = [:]
    }

    /// Clears what the parsers kept from earlier samples: call it after a seek.
    public func resetSubtitleParsers() {
        textTrackOutputs.values.forEach { $0.resetSubtitleParser() }
    }

    public func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        if trackType != .text {
            hasNonTextTracks = true
            return try delegate.track(for: id, trackType: trackType)
        }

        if let existingTrackOutput = textTrackOutputs[id] {
            return existingTrackOutput
        }

        let trackOutput = try SubtitleTranscodingTrackOutput(
            delegate: delegate.track(for: id, trackType: trackType),
            subtitleParserFactory: subtitleParserFactory
        )
        textTrackOutputs[id] = trackOutput
        return trackOutput
    }

    public func endTracks() {
        delegate.endTracks()
        if hasNonTextTracks {
            textTrackOutputs.values.forEach {
                $0.shouldSuppressParsingErrors = true
            }
        }
    }

    public func seekMap(seekMap: SeekMap) {
        delegate.seekMap(seekMap: seekMap)
    }
}
