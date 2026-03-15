//
//  SubtitleTranscodingTrackOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import Foundation
import SEPlayerCommon

final class SubtitleTranscodingTrackOutput: TrackOutput {
    var shouldSuppressParsingErrors: Bool = false

    private let delegate: TrackOutput
    private let subtitleParserFactory: SubtitleParserFactory
    private let encoder: JSONEncoder

    private var sampleDataStart = 0
    private var sampleDataEnd = 0
    private var sampleData: ByteBuffer
    private var currentSubtitleParser: SubtitleParser?
    private var currentFormat: Format?

    init(delegate: TrackOutput, subtitleParserFactory: SubtitleParserFactory) {
        self.delegate = delegate
        self.subtitleParserFactory = subtitleParserFactory
        self.encoder = JSONEncoder()
        sampleData = ByteBuffer()
    }

    func resetSubtitleParser() {
        currentSubtitleParser?.reset()
    }

    func setFormat(_ format: Format, isolation: isolated any Actor) throws {
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
            try delegate.setFormat(format, isolation: isolation)
        } else {
            try delegate.setFormat(
                format.buildUpon()
                    .setSampleMimeType(.applicationSEPlayerCues)
                    .setCodecs(sampleMimeType.rawValue)
                    .setSubsampleOffsetUs(Format.offsetSampleRelative)
                    // TODO: .setCueReplacementBehavior
                    .build(),
                isolation: isolation
            )
        }
    }

    @discardableResult
    func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult {
        if currentSubtitleParser == nil {
            return try await delegate.loadSampleData(
                input: input,
                length: length,
                allowEndOfInput: allowEndOfInput,
                isolation: isolation
            )
        }

        switch try await input.read(to: &sampleData, offset: sampleDataEnd, length: length, isolation: isolation) {
        case let .success(amount):
            sampleDataEnd += amount
            return .success(amount: amount)
        case .endOfInput:
            if allowEndOfInput {
                return .endOfInput
            }

            throw EndOfFileError()
        }
    }

    func sampleData(data: ByteBuffer, length: Int, isolation: isolated any Actor) throws {
        if currentSubtitleParser == nil {
            try delegate.sampleData(data: data, length: length, isolation: isolation)
            return
        }

        sampleData.writeBytes(data.readableBytesView[0..<length])
        sampleDataEnd += length
    }

    func sampleMetadata(time: Int64, flags: SampleFlags, size: Int, offset: Int, isolation: isolated any Actor) throws {
        if currentSubtitleParser == nil {
            try delegate.sampleMetadata(
                time: time,
                flags: flags,
                size: size,
                offset: offset,
                isolation: isolation
            )
            return
        }

        let sampleStart = sampleDataEnd - offset - size
        do {
            try currentSubtitleParser?.parse(
                data: &sampleData,
                offset: sampleStart,
                lenght: size,
                outputOptions: .allCues(),
                output: { try outputSample(cuesWithTiming: $0, timeUs: time, flags: flags, isolation: isolation) }
            )
        } catch {
            if !shouldSuppressParsingErrors {
                throw error
            }
        }

        sampleDataStart = sampleStart + size
        if sampleDataStart == sampleDataEnd {
            sampleDataStart = 0
            sampleDataEnd = 0
        }
    }

    private func outputSample(
        cuesWithTiming: CuesWithTiming,
        timeUs: Int64,
        flags: SampleFlags,
        isolation: isolated any Actor
    ) throws {
        let currentFormat = try currentFormat.checkNotNil()

        let data = try ByteBuffer(data: encoder.encode(cuesWithTiming))
        try delegate.sampleData(
            data: data,
            length: data.readableBytes,
            isolation: isolation
        )

        let outputSampleTimeUs: Int64
        if cuesWithTiming.startTimeUs == .timeUnset {
            assert(currentFormat.subsampleOffsetUs == Format.offsetSampleRelative)
            outputSampleTimeUs = timeUs
        } else if currentFormat.subsampleOffsetUs == Format.offsetSampleRelative {
            outputSampleTimeUs = timeUs + cuesWithTiming.startTimeUs
        } else {
            outputSampleTimeUs = cuesWithTiming.startTimeUs + currentFormat.subsampleOffsetUs
        }

        try delegate.sampleMetadata(
            time: outputSampleTimeUs,
            flags: flags.union(.keyframe),
            size: data.readableBytes,
            offset: 0,
            isolation: isolation
        )
    }
}
