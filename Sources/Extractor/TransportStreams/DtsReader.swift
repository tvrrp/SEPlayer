//
//  DtsReader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous DTS or DTS-HD byte stream and extracts individual samples: a core frame with the extension
/// substream that follows it, or a DTS:X Profile 2 (DTS-UHD) frame.
final class DtsReader: ElementaryStreamReader {
    private enum State {
        case findingSync
        case readingCoreHeader
        case findingExtensionSubstreamHeaderSize
        case readingExtensionSubstreamHeader
        case findingUhdHeaderSize
        case readingUhdHeader
        case readingSample
        case checkingForExtensionSubstreamAfterCore
    }

    private let language: String?
    private let roleFlags: RoleFlags
    private let containerMimeType: MimeTypes
    /// Where the frames are copied to.
    private let sampleMemory = SampleMemory(blockSize: 64 * 1024) // 64 KB

    private var formatId: String?
    private var output: TrackOutput?

    private var state = State.findingSync
    private var header: BlockBufferReader
    /// The bytes of the sample written, its header included.
    private var bytesRead = 0
    private var extensionSyncBytesRead = 0
    private var extensionSyncBytes = 0
    private var syncBytes = 0
    private var sampleDuration = CMTime.zero
    private var format: AudioFormat?
    private var sampleSize = 0
    private var coreSampleSize = 0
    private var frameType = DtsUtil.FrameType.unknown
    private var extensionSubstreamHeaderSize = 0
    private var uhdHeaderSize = 0
    private var uhdAudioChunkId = 0
    private var coreFormatPendingEmit = false
    private var time = CMTime.invalid
    private var pendingTime = CMTime.invalid
    private var hasCore = false
    private var skipsExtensionSubstreamUntilCore = false

    init(language: String? = nil, roleFlags: RoleFlags = [], containerMimeType: MimeTypes) throws {
        self.language = language
        self.roleFlags = roleFlags
        self.containerMimeType = containerMimeType
        header = try BlockBufferReader()
    }

    func seek() {
        state = .findingSync
        bytesRead = 0
        syncBytes = 0
        extensionSyncBytes = 0
        extensionSyncBytesRead = 0
        coreSampleSize = 0
        time = .invalid
        pendingTime = .invalid
        uhdAudioChunkId = 0
        coreFormatPendingEmit = false
        // An extension substream after a seek can't be used without the core frame before it.
        skipsExtensionSubstreamUntilCore = hasCore
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        self.output = try output.track(for: idGenerator.getTrackId(), trackType: .audio)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        guard pesTime.isNumeric else { return }
        // A packet that starts in the middle of a sample gives the time of the next one.
        if state != .findingSync {
            pendingTime = pesTime
        } else {
            time = pesTime
            pendingTime = .invalid
        }
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        while data.readableBytes > 0 {
            switch state {
            case .findingSync:
                guard try skipToNextSyncWord(&data) else { break }
                if skipsExtensionSubstreamUntilCore, frameType == .extensionSubstream { break }
                switch frameType {
                case .core:
                    skipsExtensionSubstreamUntilCore = false
                    state = .readingCoreHeader
                case .uhdSync,
                     .uhdNonSync:
                    state = .findingUhdHeaderSize
                default:
                    state = .findingExtensionSubstreamHeaderSize
                }
            case .readingCoreHeader:
                if try header.fill(from: &data, upTo: Self.coreHeaderSize) {
                    try parseCoreHeader()
                    try writeHeader(to: output)
                }
            case .findingExtensionSubstreamHeaderSize:
                if try header.fill(from: &data, upTo: Self.extensionSubstreamHeaderSizePrefix) {
                    extensionSubstreamHeaderSize = try min(
                        DtsUtil.parseDtsHdHeaderSize(header),
                        Self.extensionSubstreamHeaderSizeMax
                    )
                    state = .readingExtensionSubstreamHeader
                }
            case .readingExtensionSubstreamHeader:
                if try header.fill(from: &data, upTo: extensionSubstreamHeaderSize) {
                    try parseExtensionSubstreamHeader(output: output)
                    try writeHeader(to: output)
                }
            case .findingUhdHeaderSize:
                if try header.fill(from: &data, upTo: Self.uhdHeaderSizePrefix) {
                    uhdHeaderSize = try min(DtsUtil.parseDtsUhdHeaderSize(header), Self.ftocMaxHeaderSize)
                    if header.capacity > uhdHeaderSize {
                        // The header is shorter than the bytes read to find its size: give the rest back.
                        data.moveReaderIndex(to: data.readerIndex - (header.capacity - uhdHeaderSize))
                        header = try header.getSlice(at: 0, length: uhdHeaderSize)
                    }
                    state = .readingUhdHeader
                }
            case .readingUhdHeader:
                if try header.fill(from: &data, upTo: uhdHeaderSize) {
                    try parseUhdHeader(output: output)
                    try writeHeader(to: output)
                }
            case .readingSample:
                let bytesToRead = min(data.readableBytes, sampleSize - bytesRead)
                try output.sampleData(data: sampleMemory.copy(from: &data, length: bytesToRead))
                bytesRead += bytesToRead
                guard bytesRead >= sampleSize else { break }
                if frameType == .core {
                    // An extension substream may follow: it goes in the same sample.
                    coreSampleSize = sampleSize
                    bytesRead = 0
                    extensionSyncBytes = 0
                    extensionSyncBytesRead = 0
                    state = .checkingForExtensionSubstreamAfterCore
                } else {
                    let combinedSize = sampleSize + (frameType == .extensionSubstream ? coreSampleSize : 0)
                    try outputSample(output, size: combinedSize, isKeyframe: frameType != .uhdNonSync)
                    state = .findingSync
                }
            case .checkingForExtensionSubstreamAfterCore:
                while data.readableBytes > 0, extensionSyncBytesRead < 4 {
                    extensionSyncBytes = try (extensionSyncBytes << 8 | Int(data.readInt(as: UInt8.self))) & 0xFFFF_FFFF
                    extensionSyncBytesRead += 1
                }
                guard extensionSyncBytesRead == 4 else { break }
                try checkExtensionSubstream(output: output)
            }
        }
    }

    func endOfInputReached() throws {
        guard state == .checkingForExtensionSubstreamAfterCore else { return }
        let output = try output.checkNotNil()
        try emitPendingCoreFormat(output)
        if time.isNumeric {
            try outputSample(output, size: coreSampleSize, isKeyframe: true)
        }
        coreSampleSize = 0
        bytesRead = 0
        syncBytes = 0
        extensionSyncBytes = 0
        state = .findingSync
    }

    /// Goes on after the four bytes after a core frame: an extension substream of the frame, or the next frame.
    private func checkExtensionSubstream(output: TrackOutput) throws {
        if DtsUtil.frameType(word: extensionSyncBytes) == .extensionSubstream {
            try startHeader(syncWord: extensionSyncBytes)
            frameType = .extensionSubstream
            extensionSyncBytes = 0
            state = .findingExtensionSubstreamHeaderSize
            return
        }

        try emitPendingCoreFormat(output)
        try outputSample(output, size: coreSampleSize, isKeyframe: true)
        syncBytes = extensionSyncBytes
        extensionSyncBytes = 0
        frameType = DtsUtil.frameType(word: syncBytes)
        switch frameType {
        case .uhdSync,
             .uhdNonSync:
            try startHeader(syncWord: syncBytes)
            syncBytes = 0
            state = .findingUhdHeaderSize
        case .core:
            try startHeader(syncWord: syncBytes)
            syncBytes = 0
            state = .readingCoreHeader
        default:
            bytesRead = 0
            state = .findingSync
        }
    }

    private func outputSample(_ output: TrackOutput, size: Int, isKeyframe: Bool) throws {
        // packetStarted must be called before a frame is read.
        try checkArgument(time.isNumeric)
        let emittedTime = time
        try output.sampleMetadata(
            time: CMSampleTimingInfo(duration: sampleDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
            flags: isKeyframe ? .keyframe : [],
            range: 0 ..< size
        )
        time = time + sampleDuration
        if pendingTime.isNumeric {
            if pendingTime != emittedTime {
                time = pendingTime
            }
            pendingTime = .invalid
        }
        coreSampleSize = 0
    }

    private func emitPendingCoreFormat(_ output: TrackOutput) throws {
        guard coreFormatPendingEmit else { return }
        try output.setFormat(AnyFormat(format.checkNotNil()))
        coreFormatPendingEmit = false
    }

    private func writeHeader(to output: TrackOutput) throws {
        try output.sampleData(data: sampleMemory.copy(header.blockBuffer))
        bytesRead = header.capacity
        state = .readingSample
    }

    private func skipToNextSyncWord(_ data: inout BlockBufferReader) throws -> Bool {
        while data.readableBytes > 0 {
            syncBytes = try (syncBytes << 8 | Int(data.readInt(as: UInt8.self))) & 0xFFFF_FFFF
            frameType = DtsUtil.frameType(word: syncBytes)
            if frameType != .unknown {
                try startHeader(syncWord: syncBytes)
                syncBytes = 0
                return true
            }
        }
        return false
    }

    /// Starts a header with the sync word that was found.
    private func startHeader(syncWord: Int) throws {
        try header.clear()
        try header.extend(with: UInt32(truncatingIfNeeded: syncWord).bigEndianBytes)
    }

    private func parseCoreHeader() throws {
        hasCore = true
        if format == nil {
            format = try DtsUtil.parseDtsFormat(
                header,
                trackId: formatId,
                language: language,
                roleFlags: roleFlags,
                containerMimeType: containerMimeType
            )
            coreFormatPendingEmit = true
        }
        sampleSize = DtsUtil.dtsFrameSize(header)
        if let sampleRate = try format.checkNotNil().sampleRate, sampleRate > 0 {
            sampleDuration = CMTime(
                value: CMTimeValue(DtsUtil.parseDtsAudioSampleCount(header)),
                timescale: CMTimeScale(sampleRate)
            )
        }
    }

    private func parseExtensionSubstreamHeader(output: TrackOutput) throws {
        let header = try DtsUtil.parseDtsHdHeader(header)
        try updateFormat(with: header, output: output)
        sampleSize = header.frameSize
        if header.frameDuration.isValid {
            sampleDuration = header.frameDuration
        }
    }

    private func parseUhdHeader(output: TrackOutput) throws {
        let header = try DtsUtil.parseDtsUhdHeader(header, uhdAudioChunkId: &uhdAudioChunkId)
        if frameType == .uhdSync {
            try updateFormat(with: header, output: output)
        }
        sampleSize = header.frameSize
        sampleDuration = header.frameDuration.isValid ? header.frameDuration : .zero
    }

    private func updateFormat(with header: DtsUtil.DtsHeader, output: TrackOutput) throws {
        guard let sampleRate = header.sampleRate, let channelCount = header.channelCount else { return }
        let sampleMimeType = header.mimeType ?? format?.codec?.mimeType
        guard format == nil
            || coreFormatPendingEmit
            || channelCount != format?.channelCount
            || sampleRate != format?.sampleRate
            || sampleMimeType != format?.codec?.mimeType else {
            return
        }

        var format = self.format ?? AudioFormat()
        format.id = try formatId.checkNotNil()
        format.containerMimeType = containerMimeType
        format.codec = sampleMimeType.map(AudioCodec.init)
        format.channelCount = channelCount
        format.sampleRate = sampleRate
        format.language = language
        format.roleFlags = roleFlags
        self.format = format
        try output.setFormat(AnyFormat(format))
        coreFormatPendingEmit = false
    }
}

private extension DtsReader {
    static let coreHeaderSize = 18
    /// The bytes of an extension substream header that tell its size.
    static let extensionSubstreamHeaderSizePrefix = 7
    /// The largest extension substream header.
    static let extensionSubstreamHeaderSizeMax = 4096
    /// The bytes of a DTS-UHD header that tell its size.
    static let uhdHeaderSizePrefix = 6
    /// The largest DTS-UHD frame table of contents.
    static let ftocMaxHeaderSize = 5408
}
