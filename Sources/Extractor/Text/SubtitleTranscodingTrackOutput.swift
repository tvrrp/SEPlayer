//
//  SubtitleTranscodingTrackOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.SubtitleTranscodingTrackOutput
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Parses the subtitle samples written to it, and writes their cues to `delegate`.
final class SubtitleTranscodingTrackOutput: TrackOutput {
    var shouldSuppressParsingErrors: Bool = false

    private let delegate: TrackOutput
    private let subtitleParserFactory: SubtitleParserFactory
    private let encoder: CueEncoder

    private var sampleDataStart = 0
    private var sampleDataEnd = 0
    private var sampleData: BlockBufferReader?
    private var currentSubtitleParser: SubtitleParser?
    private var currentFormat: TextFormat?

    init(delegate: TrackOutput, subtitleParserFactory: SubtitleParserFactory) {
        self.delegate = delegate
        self.subtitleParserFactory = subtitleParserFactory
        self.encoder = CueEncoder()
    }

    func resetSubtitleParser() {
        currentSubtitleParser?.reset()
    }

    func setDuration(_ duration: CMTime) {
        delegate.setDuration(duration)
    }

    func setFormat(_ format: AnyFormat) throws {
        let format = try format.text.checkNotNil()

        if format != currentFormat {
            currentFormat = format
            currentSubtitleParser = if subtitleParserFactory.supportsFormat(format) {
                try subtitleParserFactory.create(format: format)
            } else {
                nil
            }
        }

        if currentSubtitleParser == nil {
            try delegate.setFormat(AnyFormat(format))
        } else {
            let behavior = try subtitleParserFactory.getCueReplacementBehavior(format: format)
            // The cues of the samples are timed relative to them.
            let cuesFormat = format.cuesFormat(cueReplacementBehavior: behavior).with { $0.subsampleOffset = nil }
            try delegate.setFormat(AnyFormat(cuesFormat))
        }
    }

    func sampleData(data: CMBlockBuffer) throws {
        if currentSubtitleParser == nil {
            try delegate.sampleData(data: data)
            return
        }

        guard !data.isEmpty else { return }
        if let sampleData {
            try sampleData.extend(with: data)
        } else {
            let sampleData = try BlockBufferReader()
            try sampleData.extend(with: data)
            self.sampleData = sampleData
        }
        sampleDataEnd += data.dataLength
    }

    func sampleMetadata(_ properties: SampleProperties) throws {
        guard let currentSubtitleParser else {
            try delegate.sampleMetadata(properties)
            return
        }

        let range = properties.dataRange
        try checkArgument(range.startIndex >= 0 && range.count >= 0)
        let sampleStart = sampleDataEnd - range.startIndex - range.count
        try checkArgument(sampleStart >= sampleDataStart)

        if range.count > 0, let sampleData {
            do {
                try currentSubtitleParser.parse(
                    data: sampleData.getSlice(at: sampleStart, length: range.count),
                    outputOptions: .allCues(),
                    output: {
                        try outputSample(cuesWithTiming: $0, time: properties.timingInfo, flags: properties.flags)
                    }
                )
            } catch {
                if !shouldSuppressParsingErrors {
                    throw error
                }
            }
        }

        sampleDataStart = sampleStart + range.count
        if sampleDataStart == sampleDataEnd {
            // The parser has used all the data it got, so it can start over.
            sampleDataStart = 0
            sampleDataEnd = 0
            sampleData = nil
        }
    }

    private func outputSample(
        cuesWithTiming: CuesWithTiming,
        time: CMSampleTimingInfo,
        flags: SampleProperties.Flags
    ) throws {
        let currentFormat = try currentFormat.checkNotNil()

        var outputSampleTime: CMTime
        if !cuesWithTiming.startTime.isValid {
            assert(currentFormat.subsampleOffset == nil)
            outputSampleTime = time.presentationTimeStamp
        } else if let subsampleOffset = currentFormat.subsampleOffset {
            let offset = CMTime(seconds: subsampleOffset, preferredTimescale: cuesWithTiming.startTime.timescale)
            outputSampleTime = cuesWithTiming.startTime + offset
        } else {
            outputSampleTime = time.presentationTimeStamp + cuesWithTiming.startTime
        }
        var duration = cuesWithTiming.duration

        // A sample that times its cues itself, as TTML in MP4 does, describes only its own time: a cue that goes on
        // past it is in the next sample too, and would show twice.
        let isTimedBySample = currentFormat.subsampleOffset != nil && time.duration.isValid && time.duration > .zero
        if isTimedBySample, cuesWithTiming.startTime.isValid, duration.isValid {
            let endTime = min(outputSampleTime + duration, time.presentationTimeStamp + time.duration)
            outputSampleTime = max(outputSampleTime, time.presentationTimeStamp)
            guard endTime > outputSampleTime else { return }
            duration = endTime - outputSampleTime
        }

        let data = try encoder.encode(cues: cuesWithTiming.cues, duration: duration)
        try delegate.sampleData(data: data)

        try delegate.sampleMetadata(
            SampleProperties(
                timingInfo: CMSampleTimingInfo(
                    duration: duration.isValid ? duration : time.duration,
                    presentationTimeStamp: outputSampleTime,
                    decodeTimeStamp: .invalid
                ),
                dataRange: 0 ..< data.dataLength,
                flags: flags.union(.keyframe)
            )
        )
    }
}
