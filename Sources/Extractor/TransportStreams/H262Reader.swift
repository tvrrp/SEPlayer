//
//  H262Reader.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses a continuous H.262 (MPEG-1 and MPEG-2 video) byte stream and extracts individual frames.
final class H262Reader: ElementaryStreamReader {
    private let userDataReader: UserDataReader?
    private let containerMimeType: MimeTypes
    private let allocator: CFAllocator
    private let userData: NalUnitTargetBuffer?
    private let csdBuffer: CsdBuffer
    private let sampleBuffer: StartCodeSampleBuffer

    private var formatId: String?
    private var output: TrackOutput?
    private var delayedOutput: DelayedSampleOutput?
    private var prefixFlags: (Bool, Bool, Bool) = (false, false, false)
    private var totalBytesWritten = 0
    private var startedFirstSample = false
    private var hasOutputFormat = false
    private var frameDuration = CMTime.zero
    private var pesTime = CMTime.invalid
    private var pesDecodeTime = CMTime.invalid
    private var samplePosition = 0
    private var sampleTime = CMTime.invalid
    private var sampleDecodeTime = CMTime.invalid
    private var sampleIsKeyframe = false
    private var sampleHasPicture = false

    init(userDataReader: UserDataReader?, containerMimeType: MimeTypes, memoryPool: CMMemoryPool = CMMemoryPool()) throws {
        self.userDataReader = userDataReader
        self.containerMimeType = containerMimeType
        allocator = memoryPool.allocator
        csdBuffer = try CsdBuffer()
        sampleBuffer = try StartCodeSampleBuffer(memoryPool: memoryPool)
        userData = userDataReader == nil
            ? nil
            : try NalUnitTargetBuffer(targetType: Self.startUserData, memoryPool: memoryPool)
    }

    func seek() {
        prefixFlags = (false, false, false)
        csdBuffer.reset()
        userData?.reset()
        userDataReader?.clear()
        sampleBuffer.reset()
        delayedOutput?.reset()
        totalBytesWritten = 0
        startedFirstSample = false
        pesTime = .invalid
        pesDecodeTime = .invalid
        sampleTime = .invalid
        sampleDecodeTime = .invalid
    }

    func createTracks(output: any ExtractorOutput, idGenerator: TsPayload.TrackIdGenerator) throws {
        idGenerator.generateNewId()
        formatId = try idGenerator.getFormatId()
        let trackOutput = try output.track(for: idGenerator.getTrackId(), trackType: .video)
        self.output = trackOutput
        delayedOutput = DelayedSampleOutput(trackOutput: trackOutput)
        try userDataReader?.createTracks(extractorOutput: output, idGenerator: idGenerator)
    }

    func packetStarted(pesTime: CMTime, decodeTime: CMTime, flags: TsPayload.PacketIndicators) {
        self.pesTime = pesTime
        pesDecodeTime = decodeTime
    }

    func consume(data: inout BlockBufferReader) throws {
        let output = try output.checkNotNil()
        guard data.readableBytes > 0 else { return }
        let view = data.readableBytesView
        var offset = view.startIndex
        let limit = view.endIndex
        defer { data.moveReaderIndex(to: limit) }
        totalBytesWritten += view.count
        try sampleBuffer.append(view)

        while true {
            let startCodeOffset = findStartCode(view, from: offset, to: limit)
            if startCodeOffset == limit {
                if !hasOutputFormat {
                    try csdBuffer.onData(view[offset ..< limit])
                }
                try userData?.appendToNalUnit(view[offset ..< limit])
                return
            }

            let startCodeValue = Int(view[startCodeOffset + 3])
            let lengthToStartCode = startCodeOffset - offset
            if !hasOutputFormat {
                if lengthToStartCode > 0 {
                    try csdBuffer.onData(view[offset ..< startCodeOffset])
                }
                let bytesAlreadyPassed = lengthToStartCode < 0 ? -lengthToStartCode : 0
                if try csdBuffer.onStartCode(startCodeValue, bytesAlreadyPassed: bytesAlreadyPassed) {
                    let (format, frameDuration) = try parseCsdBuffer()
                    try output.setFormat(AnyFormat(format))
                    self.frameDuration = frameDuration
                    hasOutputFormat = true
                }
            }

            if let userData, let userDataReader {
                var bytesAlreadyPassed = 0
                if lengthToStartCode > 0 {
                    try userData.appendToNalUnit(view[offset ..< startCodeOffset])
                } else {
                    bytesAlreadyPassed = -lengthToStartCode
                }
                if userData.endNalUnit(discardPadding: bytesAlreadyPassed) {
                    let unescaped = try NalUnitUtil.unescapeStream(
                        userData.nalBuffer,
                        length: userData.nalLength,
                        allocator: allocator
                    )
                    var userDataBuffer = BlockBufferReader(unescaped)
                    try userDataReader.consume(pesTime: sampleTime, userData: &userDataBuffer)
                }
                if startCodeValue == Self.startUserData, view[startCodeOffset + 2] == 0x01 {
                    userData.startNalUnit(type: startCodeValue)
                }
            }

            if startCodeValue == Self.startPicture || startCodeValue == Self.startSequenceHeader {
                let bytesWrittenPastStartCode = limit - startCodeOffset
                let startCodePosition = totalBytesWritten - bytesWrittenPastStartCode
                if sampleHasPicture, hasOutputFormat, sampleTime.isNumeric {
                    if let sample = try sampleBuffer.take(upTo: startCodePosition) {
                        try delayedOutput?.output(
                            data: sample,
                            time: sampleTime,
                            decodeTime: sampleDecodeTime,
                            flags: sampleIsKeyframe ? .keyframe : []
                        )
                    }
                }
                if !startedFirstSample || sampleHasPicture {
                    // The bytes before the sample that starts here belong to none.
                    try sampleBuffer.discard(upTo: startCodePosition)
                    samplePosition = startCodePosition
                    if pesTime.isNumeric {
                        sampleTime = pesTime
                        sampleDecodeTime = pesDecodeTime
                    } else if sampleTime.isNumeric {
                        sampleTime = sampleTime + frameDuration
                        sampleDecodeTime = sampleDecodeTime.isNumeric ? sampleDecodeTime + frameDuration : .invalid
                    }
                    sampleIsKeyframe = false
                    pesTime = .invalid
                    pesDecodeTime = .invalid
                    startedFirstSample = true
                }
                sampleHasPicture = startCodeValue == Self.startPicture
            } else if startCodeValue == Self.startGroup {
                sampleIsKeyframe = true
            }
            offset = startCodeOffset + 3
        }
    }

    func endOfInputReached() throws {
        try output.checkNotNil()
        if sampleTime.isNumeric, let sample = try sampleBuffer.take(upTo: totalBytesWritten) {
            try delayedOutput?.output(
                data: sample,
                time: sampleTime,
                decodeTime: sampleDecodeTime,
                flags: sampleIsKeyframe ? .keyframe : []
            )
        }
        try delayedOutput?.flush()
        try userDataReader?.flush()
    }

    private func findStartCode(_ view: BlockBufferView, from offset: Int, to limit: Int) -> Int {
        view.withContiguousStorageIfAvailable { bytes in
            let base = view.startIndex
            return base + NalUnitUtil.findNalUnit(bytes, offset: offset - base, limit: limit - base, prefixFlags: &prefixFlags)
        } ?? limit
    }

    /// The format of the sequence header and extension, and the frame duration.
    private func parseCsdBuffer() throws -> (VideoFormat, CMTime) {
        let csdData = csdBuffer.data.bytesView
        let width = Int(csdData[4]) << 4 | Int(csdData[5]) >> 4
        let height = Int(csdData[5] & 0x0F) << 8 | Int(csdData[6])
        let aspectRatioCode = Int(csdData[7] & 0xF0) >> 4
        let pixelWidthHeightRatio: Float = switch aspectRatioCode {
        case 2: Float(4 * height) / Float(3 * width)
        case 3: Float(16 * height) / Float(9 * width)
        case 4: Float(121 * height) / Float(100 * width)
        default: 1
        }

        let sequenceHeader = try csdBuffer.data.readableData()
        var format = VideoFormat()
        format.id = try formatId.checkNotNil()
        format.containerMimeType = containerMimeType
        format.codecType = FourCharacterCode(kCMVideoCodecType_MPEG2Video)
        format.codec = VideoCodec(.videoMPEG2, \.mpegVideo) { $0.sequenceHeader = sequenceHeader }
        format.size = VideoSize(width: width, height: height, pixelWidthHeightRatio: pixelWidthHeightRatio)

        var frameDuration = CMTime.zero
        let frameRateCodeMinusOne = Int(csdData[7] & 0x0F) - 1
        if Self.frameRates.indices.contains(frameRateCodeMinusOne) {
            var (numerator, denominator) = Self.frameRates[frameRateCodeMinusOne]
            let extensionPosition = csdBuffer.sequenceExtensionPosition
            if extensionPosition > 0, extensionPosition + 9 < csdData.count {
                let extensionN = Int(csdData[extensionPosition + 9] & 0x60) >> 5
                let extensionD = Int(csdData[extensionPosition + 9] & 0x1F)
                if extensionN != extensionD {
                    numerator *= extensionN + 1
                    denominator *= extensionD + 1
                }
            }
            frameDuration = CMTime(value: CMTimeValue(denominator), timescale: CMTimeScale(numerator))
        }
        return (format, frameDuration)
    }
}

private extension H262Reader {
    static let startPicture = 0x00
    static let startSequenceHeader = 0xB3
    static let startExtension = 0xB5
    static let startGroup = 0xB8
    static let startUserData = 0xB2
    static let startCodePrefix: [UInt8] = [0, 0, 1]

    /// The frame rates of frame_rate_code 1 to 8, as fractions.
    static let frameRates = [(24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1)]

    /// Collects the sequence header and its extension.
    final class CsdBuffer {
        private(set) var data: BlockBufferReader
        private(set) var sequenceExtensionPosition = 0
        private var isFilling = false

        init() throws {
            data = try BlockBufferReader()
        }

        func reset() {
            isFilling = false
            sequenceExtensionPosition = 0
        }

        /// - Returns: Whether the sequence header and its extension are complete.
        func onStartCode(_ startCodeValue: Int, bytesAlreadyPassed: Int) throws -> Bool {
            if isFilling {
                // The last bytes are the start of this start code.
                data = try data.getSlice(at: 0, length: max(data.capacity - bytesAlreadyPassed, 0))
                if sequenceExtensionPosition == 0, startCodeValue == H262Reader.startExtension {
                    sequenceExtensionPosition = data.capacity
                } else {
                    isFilling = false
                    return true
                }
            } else if startCodeValue == H262Reader.startSequenceHeader {
                isFilling = true
                try data.clear()
            }
            try onData(H262Reader.startCodePrefix)
            return false
        }

        func onData<C: Collection<UInt8>>(_ newData: C) throws {
            guard isFilling, !newData.isEmpty else { return }
            try data.extend(with: newData)
        }
    }
}
