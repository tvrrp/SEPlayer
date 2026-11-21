//
//  AdtsExtractor.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Extracts data from AAC bit streams with ADTS framing.
public final class AdtsExtractor: Extractor {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Seeks as if the bitrate were constant, from the average size of the first frames, when the length of the
        /// stream is known.
        public static let enableConstantBitrateSeeking = Flags(rawValue: 1 << 0)
        /// Seeks as if the bitrate were constant even when the length of the stream isn't known.
        public static let enableConstantBitrateSeekingAlways = Flags(rawValue: 1 << 1)
    }

    private let flags: Flags
    private let reader: AdtsReader

    private var extractorOutput: ExtractorOutput?
    private var firstSampleTime: CMTime
    private var firstFramePosition: Int?
    private var averageFrameSize: Int?
    private var hasCalculatedAverageFrameSize = false
    private var startedPacket = false
    private var hasOutputSeekMap = false

    /// - Parameter firstSampleTime: The time of the first sample, as for HLS packed audio.
    public init(flags: Flags = [], firstSampleTime: CMTime = .zero) throws {
        self.flags = flags.contains(.enableConstantBitrateSeekingAlways)
            ? flags.union(.enableConstantBitrateSeeking)
            : flags
        self.firstSampleTime = firstSampleTime
        reader = try AdtsReader(exposeId3: true, language: nil, containerMimeType: .audioAAC)
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        let startPosition = try await peekId3Header(input: input, isolation)
        var headerPosition = startPosition
        var totalValidFramesSize = 0
        var validFramesCount = 0
        while headerPosition - startPosition < RawAudioExtractorSupport.maxSniffBytes {
            guard let header = try await input.peekReader(length: 6, isolation) else { return false }
            let syncBytes = try Int(header.getInt(at: 0, as: UInt16.self))
            let frameSize = try Self.frameLength(header)
            if AdtsReader.isAdtsSyncWord(syncBytes), frameSize > 6 {
                validFramesCount += 1
                if validFramesCount >= 4, totalValidFramesSize > TSConstants.packetSize {
                    return true
                }
                try input.advancePeekPosition(length: frameSize - 6, isolation)
                totalValidFramesSize += frameSize
            } else {
                // Not a frame: look again from the next byte.
                validFramesCount = 0
                totalValidFramesSize = 0
                headerPosition += 1
                input.resetPeekPosition(isolation)
                try input.advancePeekPosition(length: headerPosition, isolation)
            }
        }
        return false
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        extractorOutput = output
        try reader.createTracks(output: output, idGenerator: TsPayload.TrackIdGenerator(firstTrackId: 0, trackIdIncrement: 1))
        output.endTracks()
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        let inputLength = input.getLength(isolation)
        let canUseConstantBitrateSeeking = flags.contains(.enableConstantBitrateSeekingAlways)
            || (flags.contains(.enableConstantBitrateSeeking) && inputLength != nil)
        if canUseConstantBitrateSeeking {
            try await calculateAverageFrameSize(input: input, isolation)
        }

        let data = try await RawAudioExtractorSupport.read(input: input, length: Self.maxPacketSize, isolation)
        maybeOutputSeekMap(inputLength: inputLength, readEndOfStream: data == nil)
        guard var data else { return .endOfInput }

        if !startedPacket {
            reader.packetStarted(pesTime: firstSampleTime, decodeTime: .invalid, flags: .dataAlignment)
            startedPacket = true
        }
        try reader.consume(data: &data)
        return .continueRead
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        startedPacket = false
        reader.seek()
        firstSampleTime = time
    }

    private func peekId3Header(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Int {
        let position = try await RawAudioExtractorSupport.peekPastId3Tags(input: input, isolation)
        if firstFramePosition == nil {
            firstFramePosition = position
        }
        return position
    }

    private func maybeOutputSeekMap(inputLength: Int?, readEndOfStream: Bool) {
        guard !hasOutputSeekMap, let extractorOutput else { return }
        let useConstantBitrateSeeking = flags.contains(.enableConstantBitrateSeeking) && (averageFrameSize ?? 0) > 0
        let sampleDuration = reader.sampleDuration
        // The seek map waits for the first frame, which gives the frame duration.
        if useConstantBitrateSeeking, !sampleDuration.isNumeric, !readEndOfStream {
            return
        }

        if useConstantBitrateSeeking, sampleDuration.isNumeric, sampleDuration > .zero, let averageFrameSize {
            let bitrate = Int(Double(averageFrameSize * 8) / sampleDuration.seconds)
            extractorOutput.seekMap(seekMap: ConstantBitrateSeekMap(
                inputLength: inputLength,
                firstFramePosition: firstFramePosition ?? 0,
                bitrate: bitrate,
                frameSize: averageFrameSize,
                allowSeeksIfLengthUnknown: flags.contains(.enableConstantBitrateSeekingAlways)
            ))
        } else {
            extractorOutput.seekMap(seekMap: Unseekable(duration: .invalid))
        }
        hasOutputSeekMap = true
    }

    /// The average size of the first frames, for constant bitrate seeking.
    private func calculateAverageFrameSize(input: any ExtractorInput, _ isolation: isolated any Actor) async throws {
        guard !hasCalculatedAverageFrameSize else { return }
        hasCalculatedAverageFrameSize = true
        averageFrameSize = nil
        input.resetPeekPosition(isolation)
        if input.getPosition(isolation) == 0 {
            _ = try await peekId3Header(input: input, isolation)
        }

        var numValidFrames = 0
        var totalValidFramesSize = 0
        while let header = try await input.peekReader(length: 6, isolation) {
            let syncBytes = try Int(header.getInt(at: 0, as: UInt16.self))
            guard AdtsReader.isAdtsSyncWord(syncBytes) else {
                numValidFrames = 0
                break
            }
            let frameSize = try Self.frameLength(header)
            guard frameSize > 6 else {
                throw ParserError.createForMalformedContainer(message: "Malformed ADTS stream")
            }
            totalValidFramesSize += frameSize
            numValidFrames += 1
            if numValidFrames == Self.numFramesForAverageFrameSize {
                break
            }
            try input.advancePeekPosition(length: frameSize - 6, isolation)
        }
        input.resetPeekPosition(isolation)
        averageFrameSize = numValidFrames > 0 ? totalValidFramesSize / numValidFrames : nil
    }
}

private extension AdtsExtractor {
    static let maxPacketSize = 2 * 1024 // 2 KB
    static let numFramesForAverageFrameSize = 1000

    /// frame_length: the 13 bits after the first 30 of a header.
    static func frameLength(_ header: BlockBufferReader) throws -> Int {
        try Int(header.getInt(at: 2, as: UInt32.self) >> 5) & 0x1FFF
    }
}
