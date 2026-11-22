//
//  DtsUtil.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.DtsUtil
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Reads the frames of DTS streams: core frames (ETSI TS 102 114), DTS-HD extension substreams and DTS:X Profile 2
/// (DTS-UHD, ETSI TS 103 491) frames.
enum DtsUtil {
    /// The highest bitrate of DTS, in bytes per second.
    static let dtsMaxRateBytesPerSecond = 1536 * 1000 / 8
    /// The highest bitrate of DTS-HD, in bytes per second.
    static let dtsHdMaxRateBytesPerSecond = 18000 * 1000 / 8
    /// The highest bitrate of DTS Express, in bits per second.
    static let dtsExpressMaxRateBitsPerSecond = 768_000

    /// The kind of a frame, from its sync word.
    enum FrameType {
        case unknown
        case core
        case extensionSubstream
        case uhdSync
        case uhdNonSync
    }

    /// What the header of a DTS-HD or DTS-UHD frame says.
    struct DtsHeader {
        let mimeType: MimeTypes?
        let channelCount: Int?
        let sampleRate: Int?
        let frameSize: Int
        /// `.invalid` if it isn't known.
        let frameDuration: CMTime
        let bitrate: Int
    }

    static func frameType(word: Int) -> FrameType {
        switch UInt32(truncatingIfNeeded: word) {
        case syncValueBE,
             syncValueLE,
             syncValue14BitBE,
             syncValue14BitLE: .core
        case syncValueExtSSBE,
             syncValueExtSSLE: .extensionSubstream
        case syncValueUhdFtocSyncBE,
             syncValueUhdFtocSyncLE: .uhdSync
        case syncValueUhdFtocNonSyncBE,
             syncValueUhdFtocNonSyncLE: .uhdNonSync
        default: .unknown
        }
    }

    /// The format of a core frame.
    static func parseDtsFormat(
        _ frame: BlockBufferReader,
        trackId: String?,
        language: String?,
        roleFlags: RoleFlags,
        containerMimeType: MimeTypes
    ) throws -> AudioFormat {
        var frameBits = try normalizedFrame(frame)
        frameBits.skipBits(32 + 1 + 5 + 1 + 7 + 14) // SYNC, FTYPE, SHORT, CPF, NBLKS, FSIZE
        let amode = try frameBits.readBits(6)
        var channelCount = channelsByAmode[amode]
        let sfreq = try frameBits.readBits(4)
        let sampleRate = sampleRateBySfreq[sfreq]
        let rate = try frameBits.readBits(5)
        let bitrate = rate >= twiceBitrateKbpsByRate.count ? nil : twiceBitrateKbpsByRate[rate] * 1000 / 2
        frameBits.skipBits(10) // MIX, DYNF, TIMEF, AUXF, HDCD, EXT_AUDIO_ID, EXT_AUDIO, ASPF
        channelCount += try frameBits.readBits(2) > 0 ? 1 : 0 // LFF
        return AudioFormat {
            $0.id = trackId
            $0.containerMimeType = containerMimeType
            $0.codec = AudioCodec(.audioDTS)
            $0.averageBitrate = bitrate
            $0.channelCount = channelCount
            $0.sampleRate = sampleRate
            $0.language = language
            $0.roleFlags = roleFlags
        }
    }

    /// The number of audio samples of the core frame whose header starts `data`.
    static func parseDtsAudioSampleCount(_ header: BlockBufferReader) -> Int {
        let data = header.bytesView
        let nblks = switch data[0] {
        case firstByteLE:
            (Int(data[5] & 0x01) << 6) | (Int(data[4] & 0xFC) >> 2)
        case firstByte14BitLE:
            (Int(data[4] & 0x07) << 4) | (Int(data[7] & 0x3C) >> 2)
        case firstByte14BitBE:
            (Int(data[5] & 0x07) << 4) | (Int(data[6] & 0x3C) >> 2)
        default:
            (Int(data[4] & 0x01) << 6) | (Int(data[5] & 0xFC) >> 2)
        }
        return (nblks + 1) * 32
    }

    /// The size of the core frame whose header starts `data`.
    static func dtsFrameSize(_ header: BlockBufferReader) -> Int {
        let data = header.bytesView
        var uses14BitPerWord = false
        var fsize: Int
        switch data[0] {
        case firstByte14BitBE:
            fsize = ((Int(data[6] & 0x03) << 12) | (Int(data[7]) << 4) | (Int(data[8] & 0x3C) >> 2)) + 1
            uses14BitPerWord = true
        case firstByteLE:
            fsize = ((Int(data[4] & 0x03) << 12) | (Int(data[7]) << 4) | (Int(data[6] & 0xF0) >> 4)) + 1
        case firstByte14BitLE:
            fsize = ((Int(data[7] & 0x03) << 12) | (Int(data[6]) << 4) | (Int(data[9] & 0x3C) >> 2)) + 1
            uses14BitPerWord = true
        default:
            fsize = ((Int(data[5] & 0x03) << 12) | (Int(data[6]) << 4) | (Int(data[7] & 0xF0) >> 4)) + 1
        }
        return uses14BitPerWord ? fsize * 16 / 14 : fsize
    }

    /// Reads the header of a DTS-HD extension substream, ETSI TS 102 114 section 7.
    static func parseDtsHdHeader(_ header: BlockBufferReader) throws -> DtsHeader {
        var headerBits = try normalizedFrame(header)
        headerBits.skipBits(32 + 8) // SYNCEXTSSH, UserDefinedBits
        let extensionSubstreamIndex = try headerBits.readBits(2) // nExtSSIndex
        let headerSizeType = try headerBits.readBit() // bHeaderSizeType
        let headerSizeInBits = headerSizeType ? 12 : 8 // nuBits4Header
        let extensionSubstreamFrameSizeBits = headerSizeType ? 20 : 16 // nuBits4ExSSFsize
        headerBits.skipBits(headerSizeInBits) // nuExtSSHeaderSize
        let extensionSubstreamFrameSize = try headerBits.readBits(extensionSubstreamFrameSizeBits) + 1

        var referenceClockCode = -1 // nuRefClockCode
        var extensionSubstreamFrameDurationCode = 0 // nuExSSFrameDurationCode
        var enableMixMetadata = false // bMixMetadataEnbl
        var mixerOutChannels = [Int]()
        let staticFieldsPresent = try headerBits.readBit()
        if staticFieldsPresent {
            referenceClockCode = try headerBits.readBits(2)
            extensionSubstreamFrameDurationCode = try 512 * (headerBits.readBits(3) + 1)
            if try headerBits.readBit() { // bTimeStampFlag
                headerBits.skipBits(32 + 4) // nuTimeStamp, nLSB
            }
            let audioPresentationsCount = try headerBits.readBits(3) + 1 // nuNumAudioPresnt
            let assetsCount = try headerBits.readBits(3) + 1 // nuNumAssets
            guard audioPresentationsCount == 1, assetsCount == 1 else {
                throw ParserError.createForUnsupportedContainerFeature(
                    message: "Multiple audio presentations or assets not supported"
                )
            }
            let activeExtensionSubstreamMask = try headerBits.readBits(extensionSubstreamIndex + 1)
            for index in 0 ..< extensionSubstreamIndex + 1 where (activeExtensionSubstreamMask >> index) & 1 == 1 {
                headerBits.skipBits(8) // nuActiveAssetMask
            }
            enableMixMetadata = try headerBits.readBit()
            if enableMixMetadata {
                headerBits.skipBits(2) // nuMixMetadataAdjLevel
                let mixerOutputMaskBits = try (headerBits.readBits(2) + 1) << 2 // nuBits4MixOutMask
                let mixerOutputConfigurationCount = try headerBits.readBits(2) + 1 // nuNumMixOutConfigs
                for _ in 0 ..< mixerOutputConfigurationCount {
                    try mixerOutChannels.append(remapChannelCount(headerBits.readBits(mixerOutputMaskBits)))
                }
            }
        }
        headerBits.skipBits(extensionSubstreamFrameSizeBits) // nuAssetFsize

        var sampleRate: Int?
        var channelCount = 0 // nuTotalNumChs
        var hasStaticFields = false
        var embeddedStereo = false // bEmbeddedStereoFlag
        var embedded6ch = false // bEmbeddedSixChFlag
        headerBits.skipBits(9 + 3) // nuAssetDescriptFsize, nuAssetIndex
        var mimeType: MimeTypes?
        if staticFieldsPresent {
            if try headerBits.readBit() { // bAssetTypeDescrPresent
                headerBits.skipBits(4) // nuAssetTypeDescriptor
            }
            if try headerBits.readBit() { // bLanguageDescrPresent
                headerBits.skipBits(24) // LanguageDescriptor
            }
            if try headerBits.readBit() { // bInfoTextPresent
                let infoTextByteSize = try headerBits.readBits(10) + 1
                headerBits.skipBits(8 * infoTextByteSize) // InfoTextString
            }
            headerBits.skipBits(5) // nuBitResolution
            sampleRate = try sampleRateByIndex[headerBits.readBits(4)] // nuMaxSampleRate
            channelCount = try headerBits.readBits(8) + 1
            hasStaticFields = true
            if try headerBits.readBit() { // bOne2OneMapChannels2Speakers
                if channelCount > 2 {
                    embeddedStereo = try headerBits.readBit()
                }
                if channelCount > 6 {
                    embedded6ch = try headerBits.readBit()
                }
                var speakerMaskLength = 0
                if try headerBits.readBit() { // bSpkrMaskEnabled
                    speakerMaskLength = try (headerBits.readBits(2) + 1) << 2 // nuNumBits4SAMask
                    headerBits.skipBits(speakerMaskLength) // nuSpkrActivityMask
                }
                let speakerRemapSetsCount = try headerBits.readBits(3) // nuNumSpkrRemapSets
                var speakerRemapSets = [Int]()
                for _ in 0 ..< speakerRemapSetsCount {
                    try speakerRemapSets.append(headerBits.readBits(speakerMaskLength)) // nuStndrSpkrLayoutMask
                }
                for remapSet in speakerRemapSets {
                    let remapMaskLength = try headerBits.readBits(5) + 1 // nuNumDecCh4Remap
                    for _ in 0 ..< remapChannelCount(remapSet) {
                        let remapMask = try headerBits.readBits(remapMaskLength) // nuRemapDecChMask
                        headerBits.skipBits(remapMask.nonzeroBitCount * 5) // nuSpkrRemapCodes
                    }
                }
            } else {
                headerBits.skipBits(3) // nuRepresentationType
            }
            try skipAssetDescriptorDynamicData(
                &headerBits,
                embeddedStereo: embeddedStereo,
                embedded6ch: embedded6ch,
                channelCount: channelCount,
                enableMixMetadata: enableMixMetadata,
                mixerOutChannels: mixerOutChannels
            )
            mimeType = try parseDecoderNavigationData(&headerBits)
        }

        var frameDuration = CMTime.invalid
        if staticFieldsPresent {
            let referenceClockFrequency = switch referenceClockCode {
            case 0: 32000
            case 1: 44100
            case 2: 48000
            default:
                throw ParserError.createForMalformedContainer(
                    message: "Unsupported reference clock code in DTS HD header: \(referenceClockCode)"
                )
            }
            frameDuration = CMTime(
                value: CMTimeValue(extensionSubstreamFrameDurationCode),
                timescale: CMTimeScale(referenceClockFrequency)
            )
        }
        return DtsHeader(
            mimeType: mimeType,
            channelCount: hasStaticFields ? channelCount : nil,
            sampleRate: sampleRate,
            frameSize: extensionSubstreamFrameSize,
            frameDuration: frameDuration,
            bitrate: 0
        )
    }

    /// The size of the DTS-HD extension substream header whose first bytes are `headerPrefix`.
    static func parseDtsHdHeaderSize(_ headerPrefix: BlockBufferReader) throws -> Int {
        var headerPrefixBits = try normalizedFrame(headerPrefix)
        headerPrefixBits.skipBits(32 + 8 + 2) // SYNCEXTSSH, UserDefinedBits, nExtSSIndex
        let headerBits = try headerPrefixBits.readBit() ? 12 : 8 // bHeaderSizeType
        return try headerPrefixBits.readBits(headerBits) + 1 // nuExtSSHeaderSize
    }

    /// Reads the header of a DTS-UHD frame, ETSI TS 103 491 sections 6.4.3 and 6.4.6.
    ///
    /// - Parameter uhdAudioChunkId: The audio chunk id, which sync frames set and other frames use.
    static func parseDtsUhdHeader(_ header: BlockBufferReader, uhdAudioChunkId: inout Int) throws -> DtsHeader {
        var headerBits = try normalizedFrame(header)
        let syncWord = try headerBits.readBits(32)
        let syncFrameFlag = UInt32(truncatingIfNeeded: syncWord) == syncValueUhdFtocSyncBE
        let ftocPayloadInBytes = try parseUnsignedVarInt(&headerBits, lengths: uhdFtocPayloadLengthTable) + 1

        var sampleRate: Int? // m_unAudioSamplRate
        var frameDuration = CMTime.invalid
        if syncFrameFlag {
            guard try headerBits.readBit() else { // m_bFullChannelBasedMixFlag
                throw ParserError.createForUnsupportedContainerFeature(
                    message: "Only supports full channel mask-based audio presentation"
                )
            }
            try checkCrc(header, sizeInBytes: ftocPayloadInBytes)
            let baseDurationIndex = try headerBits.readBits(2)
            let baseDuration = switch baseDurationIndex { // m_unBaseDuration
            case 0: 512
            case 1: 480
            case 2: 384
            default:
                throw ParserError.createForMalformedContainer(
                    message: "Unsupported base duration index in DTS UHD header: \(baseDurationIndex)"
                )
            }
            let frameDurationInClockPeriods = try baseDuration * (headerBits.readBits(3) + 1) // m_unFrameDuration
            let clockRateIndex = try headerBits.readBits(2)
            let clockRateHertz = switch clockRateIndex { // m_unClockRateInHz
            case 0: 32000
            case 1: 44100
            case 2: 48000
            default:
                throw ParserError.createForMalformedContainer(
                    message: "Unsupported clock rate index in DTS UHD header: \(clockRateIndex)"
                )
            }
            if try headerBits.readBit() { // m_bParamPresent
                headerBits.skipBits(32 + 4) // m_TimeStamp
            }
            let sampleRateMultiplier = try 1 << headerBits.readBits(2)
            sampleRate = clockRateHertz * sampleRateMultiplier
            frameDuration = CMTime(
                value: CMTimeValue(frameDurationInClockPeriods),
                timescale: CMTimeScale(clockRateHertz)
            )
        }

        var chunkPayloadBytes = 0
        if syncFrameFlag {
            // One metadata chunk.
            chunkPayloadBytes += try parseUnsignedVarInt(&headerBits, lengths: uhdMetadataChunkSizeLengthTable)
            uhdAudioChunkId = try parseUnsignedVarInt(&headerBits, lengths: uhdAudioChunkIdLengthTable)
        }
        // One audio chunk.
        if uhdAudioChunkId != 0 {
            chunkPayloadBytes += try parseUnsignedVarInt(&headerBits, lengths: uhdAudioChunkSizeLengthTable)
        }
        return DtsHeader(
            mimeType: .audioDTSX,
            channelCount: 2,
            sampleRate: sampleRate,
            frameSize: ftocPayloadInBytes + chunkPayloadBytes,
            frameDuration: frameDuration,
            bitrate: 0
        )
    }

    /// The size of the DTS-UHD frame header whose first bytes are `headerPrefix`.
    static func parseDtsUhdHeaderSize(_ headerPrefix: BlockBufferReader) throws -> Int {
        var headerPrefixBits = try normalizedFrame(headerPrefix)
        headerPrefixBits.skipBits(32) // SYNC
        return try parseUnsignedVarInt(&headerPrefixBits, lengths: uhdHeaderSizeLengthTable) + 1
    }
}

private extension DtsUtil {
    static let syncValueBE: UInt32 = 0x7FFE_8001
    static let syncValue14BitBE: UInt32 = 0x1FFF_E800
    static let syncValueLE: UInt32 = 0xFE7F_0180
    static let syncValue14BitLE: UInt32 = 0xFF1F_00E8
    static let syncValueExtSSBE: UInt32 = 0x6458_2025
    static let syncValueExtSSLE: UInt32 = 0x2520_5864
    static let syncValueUhdFtocSyncBE: UInt32 = 0x4041_1BF2
    static let syncValueUhdFtocSyncLE: UInt32 = 0xF21B_4140
    static let syncValueUhdFtocNonSyncBE: UInt32 = 0x71C4_42E8
    static let syncValueUhdFtocNonSyncLE: UInt32 = 0xE842_C471

    static let firstByteBE = UInt8(syncValueBE >> 24)
    static let firstByte14BitBE = UInt8(syncValue14BitBE >> 24)
    static let firstByteLE = UInt8(syncValueLE >> 24)
    static let firstByte14BitLE = UInt8(syncValue14BitLE >> 24)
    static let firstByteExtSSBE = UInt8(syncValueExtSSBE >> 24)
    static let firstByteExtSSLE = UInt8(syncValueExtSSLE >> 24)
    static let firstByteUhdFtocSyncBE = UInt8(syncValueUhdFtocSyncBE >> 24)
    static let firstByteUhdFtocSyncLE = UInt8(syncValueUhdFtocSyncLE >> 24)
    static let firstByteUhdFtocNonSyncBE = UInt8(syncValueUhdFtocNonSyncBE >> 24)
    static let firstByteUhdFtocNonSyncLE = UInt8(syncValueUhdFtocNonSyncLE >> 24)

    static let channelsByAmode = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8]
    static let sampleRateBySfreq = [
        -1, 8000, 16000, 32000, -1, -1, 11025, 22050, 44100, -1, -1, 12000, 24000, 48000, -1, -1,
    ]
    static let twiceBitrateKbpsByRate = [
        64, 112, 128, 192, 224, 256, 384, 448, 512, 640, 768, 896, 1024, 1152, 1280, 1536, 1920, 2048, 2304, 2560,
        2688, 2816, 2823, 2944, 3072, 3840, 4096, 6144, 7680,
    ]
    static let sampleRateByIndex = [
        8000, 16000, 32000, 64000, 128_000, 22050, 44100, 88200, 176_400, 352_800, 12000, 24000, 48000, 96000,
        192_000, 384_000,
    ]
    static let uhdFtocPayloadLengthTable = [5, 8, 10, 12]
    static let uhdMetadataChunkSizeLengthTable = [6, 9, 12, 15]
    static let uhdAudioChunkIdLengthTable = [2, 4, 6, 8]
    static let uhdAudioChunkSizeLengthTable = [9, 11, 13, 16]
    static let uhdHeaderSizeLengthTable = [5, 8, 10, 12]

    static func skipAssetDescriptorDynamicData(
        _ headerBits: inout BlockBufferBitReader,
        embeddedStereo: Bool,
        embedded6ch: Bool,
        channelCount: Int,
        enableMixMetadata: Bool,
        mixerOutChannels: [Int]
    ) throws {
        let hasDrcCoef = try headerBits.readBit()
        if hasDrcCoef { // bDRCCoefPresent
            headerBits.skipBits(8) // nuDRCCode
        }
        if try headerBits.readBit() { // bDialNormPresent
            headerBits.skipBits(5) // nuDialNormCode
        }
        if hasDrcCoef, embeddedStereo {
            headerBits.skipBits(8) // nuDRC2ChDmixCode
        }
        guard enableMixMetadata, try headerBits.readBit() else { return } // bMixMetadataPresent

        headerBits.skipBits(1 + 6) // bExternalMixFlag, nuPostMixGainAdjCode
        if try headerBits.readBits(2) < 3 { // nuControlMixerDRC
            headerBits.skipBits(3) // nuLimit4EmbeddedDRC
        } else {
            headerBits.skipBits(8) // nuCustomDRCCode
        }
        let audioScalePerChannel = try headerBits.readBit() // bEnblPerChMainAudioScale
        for mixerOutChannel in mixerOutChannels {
            headerBits.skipBits(audioScalePerChannel ? 6 * mixerOutChannel : 6) // nuMainAudioScaleCode
        }
        var channelCountsForDownmixes = [channelCount] // nDecCh
        if embedded6ch {
            channelCountsForDownmixes.append(6)
        }
        if embeddedStereo {
            channelCountsForDownmixes.append(2)
        }
        for mixerOutChannel in mixerOutChannels {
            for channelCountForDownmix in channelCountsForDownmixes {
                for _ in 0 ..< channelCountForDownmix {
                    let mask = try headerBits.readBits(mixerOutChannel) // nuMixMapMask
                    headerBits.skipBits(mask.nonzeroBitCount * 6) // nuMixCoeffs
                }
            }
        }
    }

    static func parseDecoderNavigationData(_ headerBits: inout BlockBufferBitReader) throws -> MimeTypes {
        let codingMode = try headerBits.readBits(2) // nuCodingMode
        switch codingMode {
        case 0:
            // DTS-HD coding mode that may contain several coding components.
            let extensionMask = try headerBits.readBits(12)
            return extensionMask & 0x100 != 0 ? .audioDTSExpress : .audioDTSHD
        case 1:
            // DTS-HD lossless coding mode without a CBR component.
            return .audioDTSHD
        case 2:
            // DTS-HD low bitrate mode.
            return .audioDTSExpress
        default:
            throw ParserError.createForMalformedContainer(
                message: "Unsupported coding mode in DTS HD header: \(codingMode)"
            )
        }
    }

    /// The number of channels a speaker layout mask names.
    static func remapChannelCount(_ mask: Int) -> Int {
        // One bit per speaker or pair of speakers, in the order of the masks of ETSI TS 102 114 table 7-1.
        let channelsByBit = [1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1, 2, 1, 2]
        return channelsByBit.indices.reduce(0) { count, bit in
            mask & (1 << bit) != 0 ? count + channelsByBit[bit] : count
        }
    }

    static func checkCrc(_ frame: BlockBufferReader, sizeInBytes: Int) throws {
        guard sizeInBytes >= 2, sizeInBytes <= frame.capacity else {
            throw ParserError.createForMalformedContainer(message: "CRC check failed")
        }
        let extractedCrc = try Int(frame.getInt(at: sizeInBytes - 2, as: UInt16.self))
        let calculatedCrc = CrcUtil.computeCrc16(frame.bytesView[0 ..< sizeInBytes - 2], mode: .ccittFalse)
        guard extractedCrc == Int(calculatedCrc) else {
            throw ParserError.createForMalformedContainer(message: "CRC check failed")
        }
    }

    static func parseUnsignedVarInt(_ frameBits: inout BlockBufferBitReader, lengths: [Int]) throws -> Int {
        var index = 0
        for _ in 0 ..< 3 {
            guard try frameBits.readBit() else { break }
            index += 1
        }
        var value = 0
        for lengthIndex in 0 ..< index {
            value += 1 << lengths[lengthIndex]
        }
        return try value + frameBits.readBits(lengths[index])
    }

    /// A reader of `frame` as a big-endian stream of 16-bit words: little-endian frames are byte swapped and 14-bit
    /// words are packed.
    static func normalizedFrame(_ source: BlockBufferReader) throws -> BlockBufferBitReader {
        guard let firstByte = source.bytesView.first else {
            throw ParserError.createForMalformedContainer(message: "Empty DTS frame")
        }
        let isBigEndian = [firstByteBE, firstByteExtSSBE, firstByteUhdFtocSyncBE, firstByteUhdFtocNonSyncBE]
            .contains(firstByte)
        guard !isBigEndian else { return BlockBufferBitReader(reader: source) }

        var frame = Array(source.bytesView)
        let isLittleEndian = [
            firstByteLE, firstByte14BitLE, firstByteExtSSLE, firstByteUhdFtocSyncLE, firstByteUhdFtocNonSyncLE,
        ].contains(firstByte)
        if isLittleEndian {
            var index = 0
            while index < frame.count - 1 {
                frame.swapAt(index, index + 1)
                index += 2
            }
        }
        if frame[0] == firstByte14BitBE {
            frame = packed14BitWords(frame)
        }
        return try BlockBufferBitReader(reader: BlockBufferReader(bytes: frame))
    }

    /// `frame` with the two top bits of each 16-bit word dropped, packed into the same number of bytes.
    static func packed14BitWords(_ frame: [UInt8]) -> [UInt8] {
        var packed = frame
        var writeBit = 0
        var readIndex = 0
        while readIndex + 1 < frame.count {
            let word = (Int(frame[readIndex]) << 8 | Int(frame[readIndex + 1])) & 0x3FFF
            for bit in stride(from: 13, through: 0, by: -1) {
                let byteIndex = writeBit / 8
                let mask = UInt8(0x80 >> (writeBit % 8))
                if (word >> bit) & 1 == 1 {
                    packed[byteIndex] |= mask
                } else {
                    packed[byteIndex] &= ~mask
                }
                writeBit += 1
            }
            readIndex += 2
        }
        return packed
    }
}
