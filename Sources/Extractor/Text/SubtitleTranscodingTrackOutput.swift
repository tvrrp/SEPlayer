//
//  SubtitleTranscodingTrackOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
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
    private var currentFormat: Format?

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

    func setFormat(_ format: Format) throws {
        let sampleMimeType = try format.sampleMimeType.checkNotNil()
        try checkArgument(sampleMimeType.trackType == .text)

        if format != currentFormat {
            currentFormat = format
            currentSubtitleParser = if subtitleParserFactory.supportsFormat(format) {
                try subtitleParserFactory.create(format: format)
            } else {
                nil
            }
        }

        if currentSubtitleParser == nil {
            try delegate.setFormat(format)
        } else {
            try delegate.setFormat(
                format.cuesFormat(cueReplacementBehavior: subtitleParserFactory.getCueReplacementBehavior(format: format))
                    .setSubsampleOffset(Format.offsetSampleRelative)
                    .build()
            )
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

    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>) throws {
        guard let currentSubtitleParser else {
            try delegate.sampleMetadata(time: time, flags: flags, range: range)
            return
        }

        try checkArgument(range.startIndex >= 0 && range.count >= 0)
        let sampleStart = sampleDataEnd - range.startIndex - range.count
        try checkArgument(sampleStart >= sampleDataStart)

        if range.count > 0, let sampleData {
            do {
                try currentSubtitleParser.parse(
                    data: sampleData.getSlice(at: sampleStart, length: range.count),
                    outputOptions: .allCues(),
                    output: { try outputSample(cuesWithTiming: $0, time: time, flags: flags) }
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
        flags: SampleFlags
    ) throws {
        let currentFormat = try currentFormat.checkNotNil()

        let data = try encoder.encode(cues: cuesWithTiming.cues, duration: cuesWithTiming.duration)
        try delegate.sampleData(data: data)

        let outputSampleTime: CMTime
        if !cuesWithTiming.startTime.isValid {
            assert(currentFormat.subsampleOffset == Format.offsetSampleRelative)
            outputSampleTime = time.presentationTimeStamp
        } else if currentFormat.subsampleOffset == Format.offsetSampleRelative {
            outputSampleTime = time.presentationTimeStamp + cuesWithTiming.startTime
        } else {
            outputSampleTime = cuesWithTiming.startTime + currentFormat.subsampleOffset
        }

        try delegate.sampleMetadata(
            time: CMSampleTimingInfo(
                duration: cuesWithTiming.duration.isValid ? cuesWithTiming.duration : time.duration,
                presentationTimeStamp: outputSampleTime,
                decodeTimeStamp: .invalid
            ),
            flags: flags.union(.keyframe),
            range: 0 ..< data.dataLength
        )
    }
}
