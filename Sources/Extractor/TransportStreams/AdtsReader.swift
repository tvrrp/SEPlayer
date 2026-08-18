//
//  AdtsReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.08.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Parses a continuous ADTS byte stream and extracts individual frames.
final class AdtsReader: ElementaryStreamReader {
    enum State {
        case findingSample
        case checkingAdtsHeader
        case readingId3Header
        case readingAdtsHeader
        case readingSample
    }

    // Match states used while looking for the next sample
    private enum MatchState {
        case start
        case ff
        case i
        case id
    }

    /// The duration per sample, or `.invalid` if the sample duration is not available.
    private(set) var sampleDuration: CMTime = .invalid

    private let exposeId3: Bool
    private let language: String?
    private let roleFlags: RoleFlags
    private let containerMimeType: MimeTypes

    private var headerBuffer: BlockBufferReader

    private var formatId: String?
    private var output: TrackOutput?
    private var id3Output: TrackOutput?

    private var state: State = .findingSample
    private var bytesRead = 0

    private var matchState: MatchState = .start

    private var hasCrc = false
    private var foundFirstFrame = false

    // Used to verifies sync words
    private var firstFrameVersion: Int = .versionUnset
    private var firstFrameSampleRateIndex: Int = .indexUnset

    private var currentFrameVersion = 0

    // Used when parsing the header.
    private var hasOutputFormat = false
    private var sampleSize = 0

    // Used when reading the samples.
    private var time: CMTime = .invalid

    private var currentOutput: TrackOutput?
    private var currentSampleDuration: CMTime = .zero

    /// - Parameters:
    ///   - exposeId3: True if the reader should expose ID3 information.
    ///   - language: Track language.
    ///   - roleFlags: Track role flags.
    ///   - containerMimeType: The MIME type of the container holding the stream.
    init(
        exposeId3: Bool,
        language: String?,
        roleFlags: RoleFlags = [],
        containerMimeType: MimeTypes
    ) throws {
        self.exposeId3 = exposeId3
        self.language = language
        self.roleFlags = roleFlags
        self.containerMimeType = containerMimeType
        headerBuffer = try BlockBufferReader()
        setFindingSampleState()
    }

    /// Returns whether an integer matches an ADTS SYNC word.
    static func isAdtsSyncWord(_ candidateSyncWord: Int) -> Bool {
        (candidateSyncWord & 0xFFF6) == 0xFFF0
    }

    func seek() {
        time = .invalid
        resetSync()
    }

    func createTracks(
        output: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator,
        _ isolation: isolated any Actor
    ) async throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .audio)
        self.output = trackOutput
        currentOutput = trackOutput

        guard exposeId3 else { return }
        idGenerator.generateNewId()
        let id3Output = try output.track(for: idGenerator.getTrackId(), trackType: .metadata)
        try await id3Output.setFormat(
            Format.Builder()
                .setId(idGenerator.getFormatId())
                .setContainerMimeType(containerMimeType)
                .setSampleMimeType(.applicationID3)
                .build(),
            isolation: id3Output.isolation
        )
        self.id3Output = id3Output
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        time = pesTime
    }

    func consume(data: inout BlockBufferReader, _ isolation: isolated any Actor) async throws {
        try checkTracksCreated()

        while data.readableBytes > 0 {
            switch state {
            case .findingSample:
                try findNextSample(&data)
            case .checkingAdtsHeader:
                try checkAdtsHeader(&data)
            case .readingId3Header:
                if try continueRead(source: &data, targetLength: .id3HeaderSize) {
                    try await parseId3Header(isolation)
                }
            case .readingAdtsHeader:
                let targetLength = hasCrc ? Int.headerSize + .crcSize : .headerSize
                if try continueRead(source: &data, targetLength: targetLength) {
                    try await parseAdtsHeader(isolation)
                }
            case .readingSample:
                try await readSample(&data, isolation)
            }
        }
    }

    private func resetSync() {
        foundFirstFrame = false
        setFindingSampleState()
    }

    /// Continues a read from the provided `source` into ``headerBuffer``.
    ///
    /// - Parameters:
    ///   - source: The source from which to read.
    ///   - targetLength: The target length of the read.
    /// - Returns: Whether the target length was reached.
    private func continueRead(source: inout BlockBufferReader, targetLength: Int) throws -> Bool {
        let bytesToRead = min(source.readableBytes, targetLength - bytesRead)
        if bytesToRead > 0 {
            try headerBuffer.extend(with: source.readSlice(length: bytesToRead))
            bytesRead += bytesToRead
        }
        return bytesRead == targetLength
    }

    /// Sets the state to ``State/findingSample``.
    private func setFindingSampleState() {
        state = .findingSample
        bytesRead = 0
        matchState = .start
    }

    /// Sets the state to ``State/readingId3Header`` and resets the fields required for
    /// ``parseId3Header()``.
    private func setReadingId3HeaderState() throws {
        state = .readingId3Header
        bytesRead = [UInt8].id3Identifier.count
        sampleSize = 0
        try headerBuffer.clear()
        try headerBuffer.extend(with: [UInt8].id3Identifier)
    }

    /// Sets the state to ``State/readingSample``.
    ///
    /// - Parameters:
    ///   - output: TrackOutput object to write the sample to.
    ///   - currentSampleDuration: Duration of the sample to be read.
    ///   - priorReadBytes: Size of prior read bytes.
    ///   - sampleSize: Size of the sample.
    private func setReadingSampleState(
        output: TrackOutput?,
        currentSampleDuration: CMTime,
        priorReadBytes: Int,
        sampleSize: Int
    ) {
        state = .readingSample
        bytesRead = priorReadBytes
        currentOutput = output
        self.currentSampleDuration = currentSampleDuration
        self.sampleSize = sampleSize
    }

    /// Sets the state to ``State/readingAdtsHeader``.
    private func setReadingAdtsHeaderState() throws {
        state = .readingAdtsHeader
        bytesRead = 0
        try headerBuffer.clear()
    }

    /// Sets the state to ``State/checkingAdtsHeader``.
    private func setCheckingAdtsHeaderState() {
        state = .checkingAdtsHeader
        bytesRead = 0
    }

    /// Locates the next sample start, advancing the position to the byte that immediately follows
    /// identifier. If a sample was not located, the position is advanced to the limit.
    ///
    /// - Parameter pesBuffer: The buffer whose position should be advanced.
    private func findNextSample(_ pesBuffer: inout BlockBufferReader) throws {
        let adtsData = pesBuffer.bytesView
        var position = pesBuffer.readerIndex
        let endOffset = adtsData.endIndex

        while position < endOffset {
            let data = adtsData[position]
            position += 1
            if matchState == .ff, Self.isAdtsSyncBytes(0xFF, data) {
                if try foundFirstFrame
                    || checkSyncPositionValid(pesBuffer, syncPositionCandidate: position - 2) {
                    currentFrameVersion = Int((data & 0x8) >> 3)
                    hasCrc = (data & 0x1) == 0
                    if !foundFirstFrame {
                        setCheckingAdtsHeaderState()
                    } else {
                        try setReadingAdtsHeaderState()
                    }
                    pesBuffer.moveReaderIndex(to: position)
                    return
                }
            }

            switch (matchState, data) {
            case (.start, 0xFF):
                matchState = .ff
            case (.start, UInt8(ascii: "I")):
                matchState = .i
            case (.i, UInt8(ascii: "D")):
                matchState = .id
            case (.id, UInt8(ascii: "3")):
                try setReadingId3HeaderState()
                pesBuffer.moveReaderIndex(to: position)
                return
            default:
                if matchState != .start {
                    // If matching fails in a later state, revert to `.start` and
                    // check this byte again
                    matchState = .start
                    position -= 1
                }
            }
        }
        pesBuffer.moveReaderIndex(to: position)
    }

    /// Peeks the Adts header of the current frame and checks if it is valid. If the header is valid,
    /// transition to ``State/readingAdtsHeader``; else, transition to ``State/findingSample``.
    private func checkAdtsHeader(_ buffer: inout BlockBufferReader) throws {
        guard buffer.readableBytes > 0 else {
            // Not enough data to check yet, defer this check.
            return
        }
        // Peek the next byte of buffer.
        let currentFrameSampleRateIndex = Int((try buffer.peekInt(as: UInt8.self) >> 2) & 0x0F)
        if firstFrameSampleRateIndex != .indexUnset,
           currentFrameSampleRateIndex != firstFrameSampleRateIndex {
            // Invalid header.
            resetSync()
            return
        }

        if !foundFirstFrame {
            foundFirstFrame = true
            firstFrameVersion = currentFrameVersion
            firstFrameSampleRateIndex = currentFrameSampleRateIndex
        }
        try setReadingAdtsHeaderState()
    }

    /// Checks whether a candidate SYNC word position is likely to be the position of a real SYNC
    /// word. The caller must check that the first byte of the SYNC word is `0xFF` before calling
    /// this method. This method performs the following checks:
    ///
    /// - The MPEG version of this frame must match the previously detected version.
    /// - The sample rate index of this frame must match the previously detected sample rate index.
    /// - The frame size must be at least 7 bytes
    /// - The bytes following the frame must be either another SYNC word with the same MPEG version,
    ///   or the start of an ID3 header.
    ///
    /// With the exception of the first check, if there is insufficient data in the buffer then
    /// checks are optimistically skipped and `true` is returned.
    ///
    /// - Parameters:
    ///   - pesBuffer: The buffer containing at data to check.
    ///   - syncPositionCandidate: The candidate SYNC word position. May be -1 if the first byte of
    ///     the candidate was the last byte of the previously consumed buffer.
    /// - Returns: True if all checks were passed or skipped, indicating the position is likely to be
    ///   the position of a real SYNC word. False otherwise.
    private func checkSyncPositionValid(
        _ pesBuffer: BlockBufferReader,
        syncPositionCandidate: Int
    ) throws -> Bool {
        let data = pesBuffer.bytesView
        let dataLimit = data.endIndex

        // The MPEG version of this frame must match the previously detected version.
        guard syncPositionCandidate + 1 < dataLimit else { return false }
        let secondSyncByte = data[syncPositionCandidate + 1]
        let currentFrameVersion = Int((secondSyncByte & 0x8) >> 3)
        if firstFrameVersion != .versionUnset, currentFrameVersion != firstFrameVersion {
            return false
        }

        // The sample rate index of this frame must match the previously detected sample rate index.
        if firstFrameSampleRateIndex != .indexUnset {
            guard syncPositionCandidate + 2 < dataLimit else {
                // Insufficient data for further checks.
                return true
            }
            let currentFrameSampleRateIndex = Int((data[syncPositionCandidate + 2] >> 2) & 0x0F)
            if currentFrameSampleRateIndex != firstFrameSampleRateIndex {
                return false
            }
        }

        // The frame size must be at least 7 bytes.
        guard syncPositionCandidate + 5 < dataLimit else {
            // Insufficient data for further checks.
            return true
        }
        let frameSize = Int(data[syncPositionCandidate + 3] & 0x03) << 11
            | Int(data[syncPositionCandidate + 4]) << 3
            | Int(data[syncPositionCandidate + 5]) >> 5
        if frameSize < 7 {
            return false
        }

        // The bytes following the frame must be either another SYNC word with the same MPEG version,
        // or the start of an ID3 header.
        let nextSyncPosition = syncPositionCandidate + frameSize
        guard nextSyncPosition < dataLimit else {
            // Insufficient data for further checks.
            return true
        }
        if data[nextSyncPosition] == 0xFF {
            guard nextSyncPosition + 1 < dataLimit else {
                // Insufficient data for further checks.
                return true
            }
            let nextSecondSyncByte = data[nextSyncPosition + 1]
            return Self.isAdtsSyncBytes(0xFF, nextSecondSyncByte)
                && Int((nextSecondSyncByte & 0x8) >> 3) == currentFrameVersion
        } else {
            guard data[nextSyncPosition] == UInt8(ascii: "I") else { return false }
            guard nextSyncPosition + 1 < dataLimit else {
                // Insufficient data for further checks.
                return true
            }
            guard data[nextSyncPosition + 1] == UInt8(ascii: "D") else { return false }
            guard nextSyncPosition + 2 < dataLimit else {
                // Insufficient data for further checks.
                return true
            }
            return data[nextSyncPosition + 2] == UInt8(ascii: "3")
        }
    }

    private static func isAdtsSyncBytes(_ firstByte: UInt8, _ secondByte: UInt8) -> Bool {
        isAdtsSyncWord(Int(firstByte) << 8 | Int(secondByte))
    }

    /// Parses the Id3 header.
    private func parseId3Header(_ isolation: isolated any Actor) async throws {
        if let id3Output {
            try await id3Output.sampleData(
                data: headerBuffer.blockBuffer,
                isolation: id3Output.isolation
            )
        }
        headerBuffer.moveReaderIndex(to: .id3SizeOffset)
        let dataSize = try headerBuffer.readSynchSafeInt()
        setReadingSampleState(
            output: id3Output,
            currentSampleDuration: .zero,
            priorReadBytes: .id3HeaderSize,
            sampleSize: dataSize + .id3HeaderSize
        )
    }

    /// Parses the sample header.
    private func parseAdtsHeader(_ isolation: isolated any Actor) async throws {
        let output = try output.checkNotNil()
        var header = BlockBufferBitReader(reader: headerBuffer)

        if !hasOutputFormat {
            var audioObjectType = try header.readBits(2) + 1
            if audioObjectType != 2 {
                // The stream indicates AAC-Main (1), AAC-SSR (3) or AAC-LTP (4). When the stream
                // indicates AAC-Main it's more likely that the stream contains HE-AAC (5), which
                // cannot be represented correctly in the 2 bit audio_object_type field in the ADTS
                // header. In practice when the stream indicates AAC-SSR or AAC-LTP it more commonly
                // contains AAC-LC or HE-AAC. Since indicating AAC-LC works for HE-AAC streams, we
                // pretend that we're dealing with AAC-LC and hope for the best. In practice this
                // often works.
                // TODO: log "Detected audio object type: \(audioObjectType), but assuming AAC LC."
                audioObjectType = 2
            }

            header.skipBits(5)
            let channelConfig = try header.readBits(3)

            let aacConfig = try AacConfig(
                audioObjectType: audioObjectType,
                sampleRateIndex: firstFrameSampleRateIndex,
                channelConfig: channelConfig
            )
            let format = Format.Builder()
                .setId(try formatId.checkNotNil())
                .setContainerMimeType(containerMimeType)
                .setSampleMimeType(.audioAAC)
                .setCodecs(aacConfig.codecs)
                .setChannelCount(aacConfig.channelCount)
                .setSampleRate(aacConfig.sampleRate)
                .setInitializationData(
                    try FormatInitializationData(
                        audioSpecificConfig: aacConfig.audioSpecificConfig
                    )
                )
                .setLanguage(language)
                .setRoleFlags(roleFlags)
                .build()
            // In this class a sample is an access unit, but the sample rate specifies the number of
            // PCM audio samples per second.
            sampleDuration = CMTime(
                value: CMTimeValue(Int.samplesPerFrame),
                timescale: CMTimeScale(aacConfig.sampleRate)
            )
            try await output.setFormat(format, isolation: output.isolation)
            hasOutputFormat = true
        } else {
            header.skipBits(10)
        }

        header.skipBits(4)
        var sampleSize = try header.readBits(13) - 2 /* the sync word */ - .headerSize
        if hasCrc {
            sampleSize -= .crcSize
        }
        guard sampleSize > 0 else {
            throw ParserError.createForMalformedContainer(
                message: "Invalid ADTS frame length, sample size = \(sampleSize)"
            )
        }

        setReadingSampleState(
            output: output,
            currentSampleDuration: sampleDuration,
            priorReadBytes: 0,
            sampleSize: sampleSize
        )
    }

    /// Reads the rest of the sample
    private func readSample(_ data: inout BlockBufferReader, _ isolation: isolated any Actor) async throws {
        let bytesToRead = min(data.readableBytes, sampleSize - bytesRead)
        if bytesToRead > 0 {
            if let currentOutput {
                try await currentOutput.sampleData(
                    data: data.readSlice(length: bytesToRead).blockBuffer,
                    isolation: currentOutput.isolation
                )
            } else {
                data.moveReaderIndex(forwardBy: bytesToRead)
            }
            bytesRead += bytesToRead
        }

        guard bytesRead == sampleSize else { return }
        // packetStarted method must be called before reading samples.
        try checkArgument(time.isNumeric)
        if let currentOutput {
            try await currentOutput.sampleMetadata(
                time: CMSampleTimingInfo(
                    duration: currentSampleDuration,
                    presentationTimeStamp: time,
                    decodeTimeStamp: .invalid
                ),
                flags: .keyframe,
                range: 0..<sampleSize,
                isolation: currentOutput.isolation
            )
        }
        time = time + currentSampleDuration
        setFindingSampleState()
    }

    private func checkTracksCreated() throws {
        try output.checkNotNil()
    }
}

private extension AdtsReader {
    /// Holds sample format information for AAC audio.
    struct AacConfig {
        let sampleRate: Int
        let channelCount: Int
        let codecs: String
        /// A simple AudioSpecificConfig, as defined in ISO 14496-3 4.4.1.
        let audioSpecificConfig: [UInt8]

        init(audioObjectType: Int, sampleRateIndex: Int, channelConfig: Int) throws {
            guard [Int].audioSpecificConfigSampleRates.indices.contains(sampleRateIndex) else {
                throw ParserError.createForMalformedContainer(
                    message: "Invalid AAC sampling frequency index: \(sampleRateIndex)"
                )
            }
            guard [Int].audioSpecificConfigChannelCounts.indices.contains(channelConfig) else {
                throw ParserError.createForMalformedContainer(
                    message: "Invalid AAC channel configuration: \(channelConfig)"
                )
            }
            sampleRate = [Int].audioSpecificConfigSampleRates[sampleRateIndex]
            channelCount = [Int].audioSpecificConfigChannelCounts[channelConfig]
            codecs = "mp4a.40.\(audioObjectType)"
            audioSpecificConfig = [
                UInt8(((audioObjectType << 3) & 0xF8) | ((sampleRateIndex >> 1) & 0x07)),
                UInt8(((sampleRateIndex << 7) & 0x80) | ((channelConfig << 3) & 0x78)),
            ]
        }
    }

    struct FormatInitializationData: Format.InitializationData {
        let formatDescription: CMFormatDescription

        init(audioSpecificConfig: [UInt8]) throws {
            // TODO: move from ESDescriptor
            formatDescription = try BoxParser.ESDescriptor(
                esdt: Data.esDescriptor(audioSpecificConfig: audioSpecificConfig)
            ).codecInfo
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }
    }
}

private extension BlockBufferReader {
    mutating func readSynchSafeInt() throws -> Int {
        let firstByte = Int(try readInt(as: UInt8.self))
        let secondByte = Int(try readInt(as: UInt8.self))
        let thirdByte = Int(try readInt(as: UInt8.self))
        let fourthByte = Int(try readInt(as: UInt8.self))
        return (firstByte << 21) | (secondByte << 14) | (thirdByte << 7) | fourthByte
    }
}

private extension Data {
    static func esDescriptor(audioSpecificConfig: [UInt8]) -> Data {
        // Start of the DecoderSpecificInfo.
        let decoderSpecificInfo: [UInt8] = [
            .decoderSpecificInfoTag, UInt8(audioSpecificConfig.count),
        ] + audioSpecificConfig

        // Start of the DecoderConfigDescriptor (defined in ISO/IEC 14496-1)
        let decoderConfigDescriptor: [UInt8] = [
            .objectTypeMPEG4Audio,
            .streamTypeAudio,
            0x00, 0x00, 0x00, // bufferSizeDB
            0x00, 0x00, 0x00, 0x00, // maxBitrate
            0x00, 0x00, 0x00, 0x00, // avgBitrate
        ] + decoderSpecificInfo

        // Start of the ES_Descriptor (defined in ISO/IEC 14496-1)
        let esDescriptor: [UInt8] = [
            0x00, 0x00, // ES_ID
            0x00, // flags
        ]
            + [.decoderConfigDescriptorTag, UInt8(decoderConfigDescriptor.count)]
            + decoderConfigDescriptor
            + [.slConfigDescriptorTag, 0x01, .slConfigPredefinedMP4]

        return Data([.esDescriptorTag, UInt8(esDescriptor.count)] + esDescriptor)
    }
}

private extension Int {
    static let headerSize = 5
    static let crcSize = 2

    static let id3HeaderSize = 10
    static let id3SizeOffset = 6

    static let versionUnset = -1
    static let indexUnset = -1

    static let samplesPerFrame = 1024
}

private extension UInt8 {
    static let esDescriptorTag: UInt8 = 0x03
    static let decoderConfigDescriptorTag: UInt8 = 0x04
    static let decoderSpecificInfoTag: UInt8 = 0x05
    static let slConfigDescriptorTag: UInt8 = 0x06

    static let objectTypeMPEG4Audio: UInt8 = 0x40
    static let streamTypeAudio: UInt8 = 0x15
    static let slConfigPredefinedMP4: UInt8 = 0x02
}

private extension [UInt8] {
    static let id3Identifier: [UInt8] = [
        UInt8(ascii: "I"), UInt8(ascii: "D"), UInt8(ascii: "3"),
    ]
}

private extension [Int] {
    /// Sample rates, indexed by sampling_frequency_index.
    static let audioSpecificConfigSampleRates: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    /// Channel counts, indexed by channelConfiguration.
    static let audioSpecificConfigChannelCounts: [Int] = [0, 1, 2, 3, 4, 5, 6, 8]
}
