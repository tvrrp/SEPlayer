//
//  Mp3Extractor.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.mp3.Mp3Extractor
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Extracts data from the MP3 container format: MPEG audio frames, after ID3 tags.
public final class Mp3Extractor: Extractor {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Seeks as if the bitrate were constant when the stream has no seeking information.
        public static let enableConstantBitrateSeeking = Flags(rawValue: 1 << 0)
        /// Seeks as if the bitrate were constant even when the length of the stream isn't known.
        public static let enableConstantBitrateSeekingAlways = Flags(rawValue: 1 << 1)
        /// Doesn't read the ID3 metadata, other than what seeking and gapless playback need.
        public static let disableId3Metadata = Flags(rawValue: 1 << 3)
        /// Doesn't read pictures from the ID3 metadata.
        public static let disableArtworkMetadata = Flags(rawValue: 1 << 4)
    }

    private let queue: Queue
    private let flags: Flags
    /// The time of the first sample, which the stream's own times are moved to, or `.invalid` to keep them.
    private let forcedFirstSampleTime: CMTime

    private var extractorOutput: ExtractorOutput?
    private var trackOutput: TrackOutput?
    private var synchronizedHeaderData = 0
    private var synchronizedHeader = MpegAudioUtil.Header()
    private var gaplessInfoHolder = GaplessInfoHolder()
    private var id3Metadata: Metadata?
    /// The time of the first sample read since the last seek; `.invalid` before it.
    private var basisTime = CMTime.invalid
    private var samplesRead: Int64 = 0
    /// Whether samplesRead is an exact count from the start of the stream.
    private var readingFromStart = true
    /// The samples of the stream, its encoder delay and padding included, as its Xing or Info frame counts them.
    private var streamSampleCount: Int64?
    private var firstSamplePosition = 0
    private var endPositionOfLastSampleRead: Int?
    private var sampleBytesRemaining = 0
    private var seeker: (any Mp3Seeker)?

    /// - Parameter forcedFirstSampleTime: The time of the first sample, as in HLS packed audio, whose times come from
    ///   its playlist and ID3 tags.
    public init(queue: Queue, flags: Flags = [], forcedFirstSampleTime: CMTime = .invalid) {
        self.queue = queue
        self.flags = flags.contains(.enableConstantBitrateSeekingAlways)
            ? flags.union(.enableConstantBitrateSeeking)
            : flags
        self.forcedFirstSampleTime = forcedFirstSampleTime
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        // The read synchronizes again from the start of the input, which the sniff doesn't move.
        defer { synchronizedHeaderData = 0 }
        do {
            return try await synchronize(input: input, sniffing: true, isolation)
        } catch is EndOfFileError {
            return false
        }
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        extractorOutput = output
        trackOutput = try output.track(for: 0, trackType: .audio)
        output.endTracks()
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        let trackOutput = try trackOutput.checkNotNil()

        if synchronizedHeaderData == 0 {
            do {
                guard try await synchronize(input: input, sniffing: false, isolation) else {
                    return .endOfInput
                }
            } catch is EndOfFileError {
                return .endOfInput
            }
        }

        if seeker == nil {
            let seeker = try await computeSeeker(input: input, isolation)
            self.seeker = seeker
            publishSeekMap(seeker)

            let metadata = flags.contains(.disableId3Metadata) ? nil : id3Metadata
            var format = AudioFormat(header: synchronizedHeader)
            format.containerMimeType = .audioMPEG
            format.encoderDelay = max(gaplessInfoHolder.encoderDelay ?? 0, 0)
            format.encoderPadding = max(gaplessInfoHolder.encoderPadding ?? 0, 0)
            format.metadata = metadata
            format.averageBitrate = seeker.averageBitrate
            try trackOutput.setFormat(AnyFormat(format))
            firstSamplePosition = input.getPosition(isolation)
        } else if firstSamplePosition != 0 {
            let position = input.getPosition(isolation)
            if position < firstSamplePosition {
                try input.skip(length: firstSamplePosition - position, isolation)
                input.resetPeekPosition(isolation)
            }
        }
        return try await readSample(input: input, trackOutput: trackOutput, isolation)
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        synchronizedHeaderData = 0
        basisTime = .invalid
        samplesRead = 0
        readingFromStart = position <= firstSamplePosition
        sampleBytesRemaining = 0
        endPositionOfLastSampleRead = nil
    }

    private func readSample(
        input: any ExtractorInput,
        trackOutput: TrackOutput,
        _ isolation: isolated any Actor
    ) async throws -> ExtractorReadResult {
        let seeker = try seeker.checkNotNil()
        if sampleBytesRemaining == 0 {
            input.resetPeekPosition(isolation)
            guard let headerData = try await peekHeader(input: input, isolation) else {
                return .endOfInput
            }
            guard Self.headersMatch(headerData, synchronizedHeaderData),
                  MpegAudioUtil.frameSize(headerData: headerData) != nil else {
                // Lost synchronization: look for it again from the next byte.
                try input.skip(length: 1, isolation)
                input.resetPeekPosition(isolation)
                synchronizedHeaderData = 0
                return .continueRead
            }
            _ = synchronizedHeader.setForHeaderData(headerData)
            if !basisTime.isNumeric {
                basisTime = seeker.time(at: input.getPosition(isolation))
                if forcedFirstSampleTime.isNumeric {
                    basisTime = basisTime + forcedFirstSampleTime - seeker.time(at: 0)
                }
            }
            sampleBytesRemaining = synchronizedHeader.frameSize
            endPositionOfLastSampleRead = input.getPosition(isolation) + synchronizedHeader.frameSize
        }

        let (buffer, isEndOfInput) = try await input.readFully(
            length: sampleBytesRemaining,
            allowEndOfInput: true,
            isolation
        )
        input.resetPeekPosition(isolation)
        if buffer.dataLength > 0 {
            try trackOutput.sampleData(data: buffer)
        }
        sampleBytesRemaining -= buffer.dataLength
        guard sampleBytesRemaining == 0 else {
            return isEndOfInput ? .endOfInput : .continueRead
        }

        let sampleRate = CMTimeScale(synchronizedHeader.sampleRate)
        let duration = CMTime(value: CMTimeValue(synchronizedHeader.samplesPerFrame), timescale: sampleRate)
        let readTime = basisTime + CMTime(value: samplesRead, timescale: sampleRate)
        var sample = SampleProperties(
            timingInfo: CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: readTime,
                decodeTimeStamp: .invalid
            ),
            dataRange: 0 ..< synchronizedHeader.frameSize,
            flags: .keyframe
        )
        applyGaplessInfo(to: &sample)
        try trackOutput.sampleMetadata(sample)
        samplesRead += Int64(synchronizedHeader.samplesPerFrame)
        return .continueRead
    }

    /// Moves the sample so that the audio after the encoder delay starts at the start of the stream, and trims what
    /// the delay and the padding take of it.
    ///
    /// The trim needs the sample's exact place in the stream: it is known only when reading from the start.
    private func applyGaplessInfo(to sample: inout SampleProperties) {
        guard !forcedFirstSampleTime.isNumeric, gaplessInfoHolder.hasGaplessInfo else {
            return
        }

        let timescale = sample.timingInfo.duration.timescale
        let delay = CMTime(value: CMTimeValue(max(gaplessInfoHolder.encoderDelay ?? 0, 0)), timescale: timescale)
        let readTime = sample.timingInfo.presentationTimeStamp
        guard readingFromStart else {
            sample.timingInfo.presentationTimeStamp = readTime - delay
            return
        }

        let padding = CMTime(value: CMTimeValue(max(gaplessInfoHolder.encoderPadding ?? 0, 0)), timescale: timescale)
        let end = streamSampleCount.map { CMTime(value: $0, timescale: timescale) - padding } ?? .positiveInfinity
        // In the stream's own samples, counted from its start.
        sample.timingInfo.presentationTimeStamp = CMTime(value: samplesRead, timescale: timescale)
        sample.trim(to: CMTimeRange(start: delay, end: end))
        sample.timingInfo.presentationTimeStamp = readTime - delay
    }

    /// Finds four frames whose headers match, after the ID3 tags at the start.
    ///
    /// - Returns: Whether they were found; a sniff that doesn't find them is `false`, a read throws at the end.
    private func synchronize(
        input: any ExtractorInput,
        sniffing: Bool,
        _ isolation: isolated any Actor
    ) async throws -> Bool {
        var validFrameCount = 0
        var candidateSynchronizedHeaderData = 0
        var peekedId3Bytes = 0
        var searchedBytes = 0
        input.resetPeekPosition(isolation)

        if input.getPosition(isolation) == 0 {
            let predicate: Id3Decoder.FramePredicate? = if flags.contains(.disableId3Metadata) {
                Self.requiredId3FramePredicate
            } else if flags.contains(.disableArtworkMetadata) {
                Id3Decoder.noArtworkPredicate
            } else {
                nil
            }
            id3Metadata = try await Id3Peeker.peekId3Data(
                input: input,
                framePredicate: predicate,
                maxTagPeekBytes: Self.maxSearchBytes,
                isolation
            )
            if let id3Metadata {
                gaplessInfoHolder.setFromMetadata(id3Metadata)
            }
            peekedId3Bytes = input.getPeekPosition(isolation)
            if !sniffing {
                try input.skip(length: peekedId3Bytes, isolation)
                input.resetPeekPosition(isolation)
                peekedId3Bytes = 0
            }
        }

        while true {
            guard let headerData = try await peekHeader(input: input, isolation) else {
                if validFrameCount > 0 { break }
                try maybeUpdateConstantBitrateDurationToLastSample()
                throw EndOfFileError()
            }

            let frameSize = MpegAudioUtil.frameSize(headerData: headerData)
            let matches = candidateSynchronizedHeaderData == 0
                || Self.headersMatch(headerData, candidateSynchronizedHeaderData)
            guard matches, let frameSize else {
                if searchedBytes == Self.maxSearchBytes {
                    if !sniffing {
                        try maybeUpdateConstantBitrateDurationToLastSample()
                        throw EndOfFileError()
                    }
                    return false
                }
                searchedBytes += 1
                validFrameCount = 0
                candidateSynchronizedHeaderData = 0
                if sniffing {
                    input.resetPeekPosition(isolation)
                    try input.advancePeekPosition(length: peekedId3Bytes + searchedBytes, isolation)
                } else {
                    try input.skip(length: 1, isolation)
                    input.resetPeekPosition(isolation)
                }
                continue
            }

            validFrameCount += 1
            if validFrameCount == 1 {
                _ = synchronizedHeader.setForHeaderData(headerData)
                candidateSynchronizedHeaderData = headerData
            } else if validFrameCount == 4 {
                break
            }
            try input.advancePeekPosition(length: frameSize - 4, isolation)
        }

        input.resetPeekPosition(isolation)
        synchronizedHeaderData = candidateSynchronizedHeaderData
        return true
    }

    /// The four bytes of a frame header at the peek position, or `nil` at the end of the data.
    private func peekHeader(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Int? {
        if let dataEndPosition = seeker?.dataEndPosition, input.getPeekPosition(isolation) > dataEndPosition - 4 {
            return nil
        }
        guard let header = try await input.peekReader(length: 4, isolation) else {
            return nil
        }
        return try Int(header.getInt(at: 0, as: UInt32.self))
    }

    private func computeSeeker(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> any Mp3Seeker {
        let seekFrameSeeker = try await maybeReadSeekFrame(input: input, isolation)
        let metadataSeeker = Self.mlltSeeker(metadata: id3Metadata, firstFramePosition: input.getPosition(isolation))

        let resultSeeker: any Mp3Seeker = if let metadataSeeker {
            metadataSeeker
        } else if let seekFrameSeeker {
            seekFrameSeeker
        } else {
            try await constantBitrateSeeker(input: input, isolation)
        }

        guard !(resultSeeker is ConstantBitrateSeeker),
              !resultSeeker.isSeekable(),
              flags.contains(.enableConstantBitrateSeeking) else {
            return resultSeeker
        }

        // A seeker that can't seek, with a duration: a constant bitrate of the average of the stream.
        let duration = resultSeeker.getDuration()
        let inputLength = resultSeeker.dataEndPosition ?? input.getLength(isolation)
        guard duration.isNumeric, let inputLength else {
            return try await constantBitrateSeeker(input: input, isolation)
        }
        let dataStart = resultSeeker.dataStartPosition
        let averageBitrate = ConstantBitrateSeeker.averageBitrate(byteCount: inputLength - dataStart, duration: duration)
        guard let averageBitrate else {
            return try await constantBitrateSeeker(input: input, isolation)
        }
        return ConstantBitrateSeeker(
            inputLength: inputLength,
            firstFramePosition: dataStart,
            bitrate: averageBitrate,
            frameSize: nil,
            allowSeeksIfLengthUnknown: false,
            duration: duration
        )
    }

    /// Reads the Xing, Info or VBRI frame that may come first, and moves past it.
    private func maybeReadSeekFrame(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> (any Mp3Seeker)? {
        defer { input.resetPeekPosition(isolation) }
        let frameSize = synchronizedHeader.frameSize
        let (buffer, isEndOfInput) = try await input.peekFully(length: frameSize, allowEndOfInput: true, isolation)
        guard !isEndOfInput, buffer.dataLength == frameSize else { return nil }

        var frame = BlockBufferReader(buffer)
        guard let tag = try Self.readSeekFrameTag(&frame, header: synchronizedHeader) else {
            return nil
        }
        let framePosition = input.getPosition(isolation)
        let streamLength = input.getLength(isolation)

        switch tag {
        case .xing,
             .info:
            let xingFrame = try XingFrame(header: synchronizedHeader, frame: &frame)
            if !gaplessInfoHolder.hasGaplessInfo, let delay = xingFrame.encoderDelay,
               let padding = xingFrame.encoderPadding {
                gaplessInfoHolder.encoderDelay = delay
                gaplessInfoHolder.encoderPadding = padding
            }
            streamSampleCount = xingFrame.frameCount.map { Int64($0) * Int64(synchronizedHeader.samplesPerFrame) }
            try input.skip(length: frameSize, isolation)
            guard tag == .xing else {
                return constantBitrateSeeker(
                    infoFramePosition: framePosition,
                    infoFrame: xingFrame,
                    fallbackStreamLength: streamLength
                )
            }
            return XingSeeker(xingFrame: xingFrame, position: framePosition, streamLength: streamLength)
        case .vbri:
            let seeker = try VbriSeeker(
                inputLength: streamLength,
                position: framePosition,
                header: synchronizedHeader,
                frame: &frame
            )
            try input.skip(length: frameSize, isolation)
            return seeker
        }
    }

    private func constantBitrateSeeker(
        input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> any Mp3Seeker {
        if let headerData = try await peekHeader(input: input, isolation) {
            _ = synchronizedHeader.setForHeaderData(headerData)
        }
        input.resetPeekPosition(isolation)
        return ConstantBitrateSeeker(
            inputLength: input.getLength(isolation),
            firstFramePosition: input.getPosition(isolation),
            header: synchronizedHeader,
            allowSeeksIfLengthUnknown: flags.contains(.enableConstantBitrateSeekingAlways)
        )
    }

    /// The seeker of a CBR stream with an Info frame, which gives its duration and size.
    private func constantBitrateSeeker(
        infoFramePosition: Int,
        infoFrame: XingFrame,
        fallbackStreamLength: Int?
    ) -> (any Mp3Seeker)? {
        let duration = infoFrame.duration
        guard duration.isNumeric, let frameCount = infoFrame.frameCount else {
            return nil
        }
        let streamLength: Int
        let audioLength: Int
        if let dataSize = infoFrame.dataSize {
            streamLength = infoFramePosition + dataSize
            audioLength = dataSize - infoFrame.header.frameSize
        } else if let fallbackStreamLength {
            streamLength = fallbackStreamLength
            audioLength = fallbackStreamLength - infoFramePosition - infoFrame.header.frameSize
        } else {
            return nil
        }
        let averageBitrate = ConstantBitrateSeeker.averageBitrate(byteCount: audioLength, duration: duration)
        guard let averageBitrate else { return nil }
        let frameSize = Int((Double(audioLength) / Double(frameCount)).rounded())
        return ConstantBitrateSeeker(
            inputLength: streamLength,
            firstFramePosition: infoFramePosition + infoFrame.header.frameSize,
            bitrate: averageBitrate,
            frameSize: frameSize,
            allowSeeksIfLengthUnknown: false,
            duration: duration
        )
    }

    private func publishSeekMap(_ seeker: any Mp3Seeker) {
        let rate = CMTimeScale(synchronizedHeader.sampleRate)
        let usesGaplessInfo = !forcedFirstSampleTime.isNumeric && gaplessInfoHolder.hasGaplessInfo
        let delay = usesGaplessInfo ? gaplessInfoHolder.encoderDelay ?? 0 : 0
        let padding = usesGaplessInfo && streamSampleCount != nil ? gaplessInfoHolder.encoderPadding ?? 0 : 0
        let map = Mp3PlaybackSeekMap(
            seeker: seeker,
            frameDuration: CMTime(value: Int64(synchronizedHeader.samplesPerFrame), timescale: rate),
            delay: CMTime(value: Int64(delay), timescale: rate),
            padding: CMTime(value: Int64(padding), timescale: rate)
        )
        extractorOutput?.seekMap(seekMap: map)
        trackOutput?.setDuration(map.getDuration())
    }

    /// At the end of a CBR stream, the duration up to the end of the last frame.
    private func maybeUpdateConstantBitrateDurationToLastSample() throws {
        guard let seeker = seeker as? ConstantBitrateSeeker, seeker.isSeekable(),
              let endPositionOfLastSampleRead, endPositionOfLastSampleRead != seeker.dataEndPosition else {
            return
        }
        let updated = seeker.withDataEndPosition(endPositionOfLastSampleRead)
        self.seeker = updated
        publishSeekMap(updated)
    }
}

private extension Mp3Extractor {
    /// The ID3 frames read for seeking and gapless playback: comments (`iTunSMPB`) and `MLLT`.
    static let requiredId3FramePredicate: Id3Decoder.FramePredicate = { _, frameId in
        ["COM", "COMM", "MLL", "MLLT"].contains(frameId)
    }

    static let maxSearchBytes = 128 * 1024 // 128 KB
    /// The bits of a header that stay the same in a stream: everything but the bitrate, padding and private bits.
    static let mpegAudioHeaderMask = 0xFFFE_0C00

    /// The tag of a frame that holds seeking information instead of audio.
    enum SeekFrameTag: UInt32 {
        case xing = 0x5869_6E67
        case info = 0x496E_666F
        case vbri = 0x5642_5249
    }

    /// Where a VBRI tag is: after the header of the frame and 32 bytes.
    static let vbriTagOffset = 36

    static func headersMatch(_ headerA: Int, _ headerB: Int) -> Bool {
        headerA & mpegAudioHeaderMask == headerB & mpegAudioHeaderMask
    }

    /// Reads the tag of a frame of seeking information, leaving `frame` after it, or `nil` for a frame of audio.
    static func readSeekFrameTag(
        _ frame: inout BlockBufferReader,
        header: MpegAudioUtil.Header
    ) throws -> SeekFrameTag? {
        // A Xing or Info tag comes after the side information, whose size depends on the version and the channels.
        let isMono = header.channels == 1
        let isVersion1 = header.version & 1 != 0
        let xingTagOffset = isVersion1 ? (isMono ? 21 : 36) : (isMono ? 13 : 21)

        for (offset, tags) in [(xingTagOffset, [SeekFrameTag.xing, .info]), (vbriTagOffset, [.vbri])]
            where frame.capacity >= offset + 4 {
            frame.moveReaderIndex(to: offset)
            if let tag = try SeekFrameTag(rawValue: frame.readInt()), tags.contains(tag) {
                return tag
            }
        }
        return nil
    }

    static func mlltSeeker(metadata: Metadata?, firstFramePosition: Int) -> MlltSeeker? {
        guard let metadata, let mlltFrame = metadata.first(of: MlltFrame.self) else {
            return nil
        }
        // TLEN: the length in milliseconds.
        let duration = metadata.entries
            .compactMap { $0 as? TextInformationFrame }
            .first { $0.id == "TLEN" }
            .flatMap { Int64($0.value) }
            .map { CMTime(value: $0, timescale: 1000) }
        return MlltSeeker(firstFramePosition: firstFramePosition, mlltFrame: mlltFrame, duration: duration ?? .invalid)
    }
}
