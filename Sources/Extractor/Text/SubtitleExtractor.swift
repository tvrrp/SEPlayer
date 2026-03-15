//
//  SubtitleExtractor.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import Foundation
import SEPlayerCommon

public class SubtitleExtractor: Extractor {
    private let queue: Queue
    private let subtitleParser: SubtitleParser
    private let encoder: JSONEncoder
    private let format: Format?
    private var samples: [Sample]

    private var subtitleData: ByteBuffer
    private var trackOutput: TrackOutput!
    private var bytesRead: Int
    private var state: State
    private var timestamps: [Int64]
    private var seekTimeUs: Int64

    public init(
        queue: Queue,
        subtitleParser: SubtitleParser,
        format: Format?
    ) {
        self.queue = queue
        self.subtitleParser = subtitleParser
        self.format = format?
            .buildUpon()
            .setSampleMimeType(.applicationSEPlayerCues)
            .setCodecs(format?.sampleMimeType?.rawValue)
            // TODO: .setCueReplacementBehavior
            .build()

        encoder = JSONEncoder()
        samples = []
        subtitleData = ByteBuffer()
        bytesRead = .zero
        state = .created
        timestamps = []
        seekTimeUs = .timeUnset
    }

    public func shiff(input: ExtractorInput, isolation: isolated Actor) async throws -> Bool {
        return true
    }

    public func initialize(output: any ExtractorOutput, isolation: isolated any Actor) throws {
        try checkState(state == .created)

        trackOutput = try output.track(for: .zero, trackType: .text)
        if let format {
            try trackOutput.setFormat(format, isolation: isolation)
            output.endTracks()
            // TODO: output.seekMap(seekMap: <#T##any SeekMap#>)
        }
        state = .initialized
    }

    public func read(input: any ExtractorInput, isolation: isolated any Actor) async throws -> ExtractorReadResult {
        try checkState(state != .created && state != .released)

        if state == .initialized {
            let length = input.getLength(isolation: isolation) ?? .defaultBufferSize
            if length > subtitleData.capacity {
                subtitleData.reserveCapacity(length)
            }

            bytesRead = 0
            state = .extracting
        }

        if state == .extracting {
            let inputFinished = try await readFromInput(input, isolation: isolation)
            if inputFinished {
                try await parseAndWriteToOutput(isolation: isolation)
                state = .finished
            }
        }

        if state == .seeking {
            let inputFinished = try await skipInput(input, isolation: isolation)
            if inputFinished {
                try writeToOutput(isolation: isolation)
                state = .finished
            }
        }

        if state == .finished {
            return .endOfInput
        }

        return .continueRead
    }

    public func seek(to position: Int, timeUs: Int64, isolation: isolated any Actor) throws {
        try checkState(state != .created && state != .released)
        seekTimeUs = timeUs

        if state == .extracting {
            state = .initialized
        }

        if state == .finished {
            state = .seeking
        }
    }

    public func release(isolation: isolated any Actor) {
        guard state != .released else { return }

        subtitleParser.reset()
        state = .released
    }

    private func skipInput(_ input: ExtractorInput, isolation: isolated any Actor) async throws -> Bool {
        if case .endOfInput = try await input.skip(
            length: input.getLength(isolation: isolation) ?? .defaultBufferSize,
            isolation: isolation
        ) {
            return true
        }

        return false
    }

    private func readFromInput(_ input: ExtractorInput, isolation: isolated any Actor) async throws -> Bool {
        if subtitleData.capacity == bytesRead {
            subtitleData.reserveCapacity(subtitleData.capacity + .defaultBufferSize)
        }

        let result = try await input.read(
            to: &subtitleData,
            offset: bytesRead,
            length: subtitleData.capacity - bytesRead,
            isolation: isolation
        )

        if case let .success(amount) = result {
            bytesRead += amount
        }

        let inputLength = input.getLength(isolation: isolation)
        return (inputLength != nil && inputLength == bytesRead) || DataReaderReadResult.endOfInput == result
    }

    private func parseAndWriteToOutput(isolation: isolated any Actor) async throws {
        let outputOptions = seekTimeUs != .timeUnset
            ? SubtitleParserOutputOptions.cuesAfterThenRemainingCuesBefore(startTimeUs: seekTimeUs)
            : SubtitleParserOutputOptions.allCues()

        try subtitleParser.parse(
            data: &subtitleData,
            offset: 0,
            lenght: bytesRead,
            outputOptions: outputOptions,
            output: { cuesWithTiming in
                let sample = try Sample(
                    timeUs: cuesWithTiming.startTimeUs,
                    cues: ByteBuffer(data: encoder.encode(cuesWithTiming))
                )

                samples.append(sample)
                if seekTimeUs == .timeUnset || cuesWithTiming.endTimeUs >= seekTimeUs {
                    try writeToOutput(sample: sample, isolation: isolation)
                }
            }
        )

        samples.sort()
        timestamps = samples.map { $0.timeUs }
        subtitleData.clear()
    }

    private func writeToOutput(isolation: isolated any Actor) throws {
        let index = if seekTimeUs == .timeUnset {
            Int.zero
        } else {
            Util.binarySearch(array: timestamps, value: seekTimeUs, inclusive: true, stayInBounds: true)
        }

        try samples[index..<samples.count].forEach {
            try writeToOutput(sample: $0, isolation: isolation)
        }
    }

    private func writeToOutput(sample: Sample, isolation: isolated any Actor) throws {
        try trackOutput.sampleData(
            data: sample.cues,
            length: sample.cues.readableBytes,
            isolation: isolation
        )

        try trackOutput.sampleMetadata(
            time: sample.timeUs,
            flags: .keyframe,
            size: 0,
            offset: 0,
            isolation: isolation
        )
    }

    private func checkState(_ check: @autoclosure () -> Bool) throws {
        if check() { throw ErrorBuilder(errorDescription: "Wrong state") } // TODO: real error
    }
}

private extension SubtitleExtractor {
    enum State {
        case created
        case initialized
        case extracting
        case seeking
        case finished
        case released
    }

    struct Sample: Comparable {
        let timeUs: Int64
        let cues: ByteBuffer

        static func < (lhs: SubtitleExtractor.Sample, rhs: SubtitleExtractor.Sample) -> Bool {
            lhs.timeUs < rhs.timeUs
        }

        static func == (lhs: SubtitleExtractor.Sample, rhs: SubtitleExtractor.Sample) -> Bool {
            lhs.timeUs == rhs.timeUs
        }
    }
}

private extension Int {
    static let defaultBufferSize = 1024
}
