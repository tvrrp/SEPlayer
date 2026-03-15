//
//  SubtitleTranscodingExtractorOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

final class SubtitleTranscodingExtractorOutput: ExtractorOutput {
    private let delegate: ExtractorOutput
    private let subtitleParserFactory: SubtitleParserFactory
    private var textTrackOutputs: [Int: SubtitleTranscodingTrackOutput]

    private var hasNonTextTracks = false

    init(delegate: ExtractorOutput, subtitleParserFactory: SubtitleParserFactory) {
        self.delegate = delegate
        self.subtitleParserFactory = subtitleParserFactory
        self.textTrackOutputs = [:]
    }

    func resetSubtitleParsers() {
        textTrackOutputs.values.forEach { $0.resetSubtitleParser() }
    }

    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        if trackType != .text {
            hasNonTextTracks = true
            return try delegate.track(for: id, trackType: trackType)
        }

        if let existingTrackOutput = textTrackOutputs[id] {
            return existingTrackOutput
        }

        let trackOutput = SubtitleTranscodingTrackOutput(
            delegate: try delegate.track(for: id, trackType: trackType),
            subtitleParserFactory: subtitleParserFactory
        )
        textTrackOutputs[id] = trackOutput
        return trackOutput
    }

    func endTracks() {
        delegate.endTracks()
        if hasNonTextTracks {
            textTrackOutputs.values.forEach {
                $0.shouldSuppressParsingErrors = true
            }
        }
    }

    func seekMap(seekMap: SeekMap) {
        delegate.seekMap(seekMap: seekMap)
    }
}
