//
//  SubtitleExtractor.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import CoreMedia
import SEPlayerCommon

public final class SubtitleExtractor: Extractor {
    private let queue: Queue
    private let subtitleParser: SubtitleParser
    private let encoder: CueEncoder
    private let format: Format?
    private var samples: [Sample]

    private var subtitleData: BlockBufferReader?
    private var extractorOutput: ExtractorOutput?
    private var trackOutput: TrackOutput?
    private var seekMap: SubtitleSeekMap?
    private var bytesRead: Int
    private var state: State
    private var timestamps: [CMTime]
    private var seekTime: CMTime

    public init(
        queue: Queue,
        subtitleParser: SubtitleParser,
        format: Format?
    ) {
        self.queue = queue
        self.subtitleParser = subtitleParser
        self.format = format?.cuesFormat(cueReplacementBehavior: subtitleParser.getCueReplacementBehavior()).build()

        encoder = CueEncoder()
        samples = []
        bytesRead = .zero
        state = .created
        timestamps = []
        seekTime = .invalid
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        // TODO: Implement sniffing. For now it's safe to return true, as this extractor is meant to be the only one
        // an ExtractorsFactory returns.
        return true
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        assert(queue.isCurrent())
        try checkState(state == .created)

        extractorOutput = output
        let trackOutput = try output.track(for: .zero, trackType: .text)
        self.trackOutput = trackOutput
        if let format {
            try trackOutput.setFormat(format)
            output.endTracks()
            let seekMap = SubtitleSeekMap(duration: .invalid)
            self.seekMap = seekMap
            output.seekMap(seekMap: seekMap)
        }
        state = .initialized
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        assert(queue.isCurrent())
        try checkState(state != .created && state != .released)

        if state == .initialized {
            subtitleData = try BlockBufferReader()
            bytesRead = 0
            state = .extracting
        }

        if state == .extracting {
            let inputFinished = try await readFromInput(input, isolation)
            if inputFinished {
                try await parseAndWriteToOutput(isolation)
                state = .finished
            }
        }

        if state == .seeking {
            let inputFinished = try skipInput(input, isolation)
            if inputFinished {
                try await writeToOutput(isolation)
                state = .finished
            }
        }

        if state == .finished {
            return .endOfInput
        }

        return .continueRead
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        try checkState(state != .created && state != .released)
        seekTime = time

        if state == .extracting {
            state = .initialized
        }

        if state == .finished {
            state = .seeking
        }
    }

    public func release(_ isolation: isolated any Actor) {
        guard state != .released else { return }

        subtitleParser.reset()
        state = .released
    }

    private func skipInput(_ input: any ExtractorInput, _ isolation: isolated any Actor) throws -> Bool {
        let length = input.getLength(isolation).map { $0 - input.getPosition(isolation) } ?? .defaultBufferSize
        return try input.skip(length: length, allowEndOfInput: true, isolation)
    }

    private func readFromInput(_ input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        let subtitleData = try subtitleData.checkNotNil()
        let inputLength = input.getLength(isolation)
        let length = inputLength.map { $0 - bytesRead } ?? .defaultBufferSize
        guard length > 0 else { return true }

        let (blockBuffer, isEndOfInput) = try await input.readFully(length: length, allowEndOfInput: true, isolation)
        if !blockBuffer.isEmpty {
            try subtitleData.extend(with: blockBuffer)
            bytesRead += blockBuffer.dataLength
        }

        return (inputLength != nil && inputLength == bytesRead) || isEndOfInput
    }

    private func parseAndWriteToOutput(_ isolation: isolated any Actor) async throws {
        let outputOptions = seekTime.isValid
            ? SubtitleParserOutputOptions.cuesAfterThenRemainingCuesBefore(startTime: seekTime)
            : SubtitleParserOutputOptions.allCues()

        var maxEndTime = CMTime.invalid
        // Written once parsing is done: the track output runs in its own isolation.
        var samplesToWrite: [Sample] = []
        if let subtitleData, bytesRead > 0 {
            try subtitleParser.parse(
                data: subtitleData.getSlice(at: 0, length: bytesRead),
                outputOptions: outputOptions,
                output: { cuesWithTiming in
                    let sample = Sample(
                        time: cuesWithTiming.startTime,
                        duration: cuesWithTiming.duration,
                        cues: try encoder.encode(cues: cuesWithTiming.cues, duration: cuesWithTiming.duration)
                    )

                    samples.append(sample)
                    if cuesWithTiming.endTime.isValid {
                        maxEndTime = maxEndTime.isValid ? max(maxEndTime, cuesWithTiming.endTime) : cuesWithTiming.endTime
                    }
                    if !seekTime.isValid || cuesWithTiming.endTime >= seekTime {
                        samplesToWrite.append(sample)
                    }
                }
            )
        }

        SELogger.debug(.subtitles, "Parsed \(samples.count) cues, \(samplesToWrite.count) written\(maxEndTime.isValid ? ", to \(maxEndTime.seconds)s" : "")")
        for sample in samplesToWrite {
            try await writeToOutput(sample: sample, isolation)
        }

        samples.sort()
        timestamps = samples.map { $0.time }
        // Duration is exact after parsing all subtitle cues.
        if maxEndTime.isValid {
            let trackOutput = try trackOutput.checkNotNil()
            trackOutput.setDuration(maxEndTime)
            if let seekMap {
                seekMap.duration = maxEndTime
                extractorOutput?.seekMap(seekMap: seekMap)
            }
        }
        subtitleData = nil
    }

    private func writeToOutput(_ isolation: isolated any Actor) async throws {
        let index = if seekTime.isValid {
            Util.binarySearch(array: timestamps, value: seekTime, inclusive: true, stayInBounds: true)
        } else {
            Int.zero
        }

        guard index < samples.count else { return }
        for sample in samples[index..<samples.count] {
            try await writeToOutput(sample: sample, isolation)
        }
    }

    private func writeToOutput(sample: Sample, _ isolation: isolated any Actor) async throws {
        let trackOutput = try trackOutput.checkNotNil()
        try trackOutput.sampleData(data: sample.cues)
        try trackOutput.sampleMetadata(
            time: CMSampleTimingInfo(
                duration: sample.duration,
                presentationTimeStamp: sample.time,
                decodeTimeStamp: .invalid
            ),
            flags: .keyframe,
            range: 0..<sample.cues.dataLength
        )
    }

    private func checkState(_ check: @autoclosure () -> Bool) throws {
        if !check() { throw ErrorBuilder(errorDescription: "Wrong state") } // TODO: real error
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
        let time: CMTime
        let duration: CMTime
        let cues: CMBlockBuffer

        static func < (lhs: Sample, rhs: Sample) -> Bool {
            lhs.time < rhs.time
        }

        static func == (lhs: Sample, rhs: Sample) -> Bool {
            lhs.time == rhs.time
        }
    }

    /// Seeks to the start of the input: the extractor reads all of it, and outputs the cues from the seek time.
    final class SubtitleSeekMap: SeekMap {
        var duration: CMTime

        init(duration: CMTime) {
            self.duration = duration
        }

        func isSeekable() -> Bool { true }
        func getDuration() -> CMTime { duration }
        func getSeekPoints(for time: CMTime) -> SeekPoints { SeekPoints(first: .start) }
    }
}

private extension Int {
    static let defaultBufferSize = 1024
}
