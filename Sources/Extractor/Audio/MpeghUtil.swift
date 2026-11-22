//
//  MpeghUtil.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.MpeghUtil
//  Copyright (C) 2024 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation
import SEPlayerCommon

/// Reads MPEG-H 3D audio streams in MHAS packets, ISO/IEC 23008-3.
enum MpeghUtil {
    /// The header of an MHAS packet, section 14.2.1.
    struct MhasPacketHeader {
        enum PacketType {
            static let fillData = 0
            static let mpegh3daConfig = 1
            static let mpegh3daFrame = 2
            static let audioSceneInfo = 3
            static let sync = 6
            static let syncGap = 7
            static let marker = 8
            static let crc16 = 9
            static let crc32 = 10
            static let descriptor = 11
            static let userInteraction = 12
            static let loudnessDrc = 13
            static let bufferInfo = 14
            static let globalCrc16 = 15
            static let globalCrc32 = 16
            static let audioTruncation = 17
            static let genData = 18
            static let earcon = 19
            static let pcmConfig = 20
            static let pcmData = 21
            static let loudness = 22
        }

        var packetType = 0
        var packetLabel: Int64 = 0
        var packetLength = 0
    }

    /// What an `mpegh3daConfig()` says.
    struct Mpegh3daConfig {
        let profileLevelIndication: Int
        let samplingFrequency: Int
        let standardFrameLength: Int
        let compatibleProfileLevelSet: [UInt8]?
    }

    static func isSyncWord(_ word: Int) -> Bool {
        word & 0xFFFFFF == mhasSyncWord
    }

    /// Reads an MHAS packet header.
    ///
    /// - Returns: Whether the whole header was there.
    static func parseMhasPacketHeader(_ data: inout BlockBufferBitReader, header: inout MhasPacketHeader) throws -> Bool {
        guard let packetType = try readEscapedIntValue(&data, 3, 8, 8) else {
            return false
        }
        header.packetType = packetType
        guard let packetLabel = try readEscapedLongValue(&data, 2, 8, 32) else {
            return false
        }
        header.packetLabel = packetLabel
        if packetLabel > 0x10 {
            throw ParserError.createForUnsupportedContainerFeature(
                message: "Contains sub-stream with an invalid packet label \(packetLabel)"
            )
        }
        if packetLabel == 0 {
            switch packetType {
            case MhasPacketHeader.PacketType.mpegh3daConfig,
                 MhasPacketHeader.PacketType.audioTruncation,
                 MhasPacketHeader.PacketType.mpegh3daFrame:
                throw ParserError.createForMalformedContainer(
                    message: "MHAS packet of type \(packetType) with invalid packet label 0"
                )
            default:
                break
            }
        }
        guard let packetLength = try readEscapedIntValue(&data, 11, 24, 24) else {
            return false
        }
        header.packetLength = packetLength
        return true
    }

    /// Reads an `mpegh3daConfig()`, section 5.2.2.1.
    static func parseMpegh3daConfig(_ data: inout BlockBufferBitReader) throws -> Mpegh3daConfig {
        var compatibleProfileLevelSet: [UInt8]?
        let profileLevelIndication = try data.readBits(8)
        let samplingFrequencyIndex = try data.readBits(5)
        let usacSamplingFrequency = if samplingFrequencyIndex == 0x1F {
            try data.readBits(24)
        } else {
            try samplingFrequency(index: samplingFrequencyIndex)
        }
        let coreSbrFrameLengthIndex = try data.readBits(3)
        let outputFrameLength = try outputFrameLength(index: coreSbrFrameLengthIndex)
        let sbrRatioIndex = try sbrRatioIndex(index: coreSbrFrameLengthIndex)
        data.skipBits(2) // cfg_reserved, receiverDelayCompensation
        try skipSpeakerConfig3d(&data) // referenceLayout
        let numSignals = try parseSignals3d(&data) // frameworkConfig3d
        try skipMpegh3daDecoderConfig(&data, numSignals: numSignals, sbrRatioIndex: sbrRatioIndex)
        if try data.readBit() { // usacConfigExtensionPresent
            let numConfigExtensions = try (readEscapedIntValue(&data, 2, 4, 8) ?? 0) + 1
            for _ in 0 ..< numConfigExtensions {
                let usacConfigExtType = try readEscapedIntValue(&data, 4, 8, 16) ?? 0
                let usacConfigExtLength = try readEscapedIntValue(&data, 4, 8, 16) ?? 0
                if usacConfigExtType == 7 { // ID_CONFIG_EXT_COMPATIBLE_PROFILELVL_SET
                    let numCompatibleSets = try data.readBits(4) + 1
                    data.skipBits(4) // reserved
                    var sets = [UInt8]()
                    for _ in 0 ..< numCompatibleSets {
                        try sets.append(UInt8(data.readBits(8)))
                    }
                    compatibleProfileLevelSet = sets
                } else {
                    data.skipBits(8 * usacConfigExtLength)
                }
            }
        }

        let resamplingRatio = try resamplingRatio(usacSamplingFrequency: usacSamplingFrequency)
        return Mpegh3daConfig(
            profileLevelIndication: profileLevelIndication,
            samplingFrequency: Int(Double(usacSamplingFrequency) * resamplingRatio),
            standardFrameLength: Int(Double(outputFrameLength) * resamplingRatio),
            compatibleProfileLevelSet: compatibleProfileLevelSet
        )
    }

    /// Reads an `audioTruncationInfo()`.
    ///
    /// - Returns: The number of samples to truncate.
    static func parseAudioTruncationInfo(_ data: inout BlockBufferBitReader) throws -> Int {
        guard try data.readBit() else { return 0 } // isActive
        data.skipBits(2) // reserved, truncFromBegin
        return try data.readBits(13)
    }
}

private extension MpeghUtil {
    static let mhasSyncWord = 0xC001A5

    static func outputFrameLength(index: Int) throws -> Int {
        switch index {
        case 0: 768
        case 1: 1024
        case 2,
             3: 2048
        case 4: 4096
        default:
            throw ParserError.createForUnsupportedContainerFeature(message: "Unsupported coreSbrFrameLengthIndex \(index)")
        }
    }

    static func sbrRatioIndex(index: Int) throws -> Int {
        switch index {
        case 0,
             1: 0
        case 2: 2
        case 3: 3
        case 4: 1
        default:
            throw ParserError.createForUnsupportedContainerFeature(message: "Unsupported coreSbrFrameLengthIndex \(index)")
        }
    }

    static func resamplingRatio(usacSamplingFrequency: Int) throws -> Double {
        switch usacSamplingFrequency {
        case 96000,
             88200,
             48000,
             44100: 1
        case 64000,
             58800,
             32000,
             29400: 1.5
        case 24000,
             22050: 2
        case 16000,
             14700: 3
        default:
            throw ParserError.createForUnsupportedContainerFeature(
                message: "Unsupported sampling rate \(usacSamplingFrequency)"
            )
        }
    }

    static func samplingFrequency(index: Int) throws -> Int {
        let frequencies: [Int: Int] = [
            0: 96000, 1: 88200, 2: 64000, 3: 48000, 4: 44100, 5: 32000, 6: 24000, 7: 22050, 8: 16000, 9: 12000,
            10: 11025, 11: 8000, 12: 7350, 15: 57600, 16: 51200, 17: 40000, 18: 38400, 19: 34150, 20: 28800,
            21: 25600, 22: 20000, 23: 19200, 24: 17075, 25: 14400, 26: 12800, 27: 9600,
        ]
        guard let frequency = frequencies[index] else {
            throw ParserError.createForUnsupportedContainerFeature(message: "Unsupported sampling rate index \(index)")
        }
        return frequency
    }

    static func skipSpeakerConfig3d(_ data: inout BlockBufferBitReader) throws {
        let speakerLayoutType = try data.readBits(2)
        if speakerLayoutType == 0 {
            data.skipBits(6) // cicpSpeakerLayoutIdx
            return
        }
        let numberOfSpeakers = try (readEscapedIntValue(&data, 5, 8, 16) ?? 0) + 1
        if speakerLayoutType == 1 {
            data.skipBits(7 * numberOfSpeakers) // cicpSpeakerIdx per speaker
        } else if speakerLayoutType == 2 {
            try skipMpegh3daFlexibleSpeakerConfig(&data, numberOfSpeakers: numberOfSpeakers)
        }
    }

    static func skipMpegh3daFlexibleSpeakerConfig(_ data: inout BlockBufferBitReader, numberOfSpeakers: Int) throws {
        let angularPrecision = try data.readBit()
        let angularPrecisionDegrees = angularPrecision ? 1 : 5
        let elevationAngleBits = angularPrecision ? 7 : 5
        let azimuthAngleBits = angularPrecision ? 8 : 6
        var speaker = 0
        while speaker < numberOfSpeakers {
            var azimuthAngle = 0
            if try data.readBit() { // isCICPspeakerIdx
                data.skipBits(7) // cicpSpeakerIdx
            } else {
                let elevationClass = try data.readBits(2)
                if elevationClass == 3 {
                    let elevationAngle = try data.readBits(elevationAngleBits) * angularPrecisionDegrees
                    if elevationAngle != 0 {
                        data.skipBit() // elevationDirection
                    }
                }
                azimuthAngle = try data.readBits(azimuthAngleBits) * angularPrecisionDegrees
                if azimuthAngle != 0, azimuthAngle != 180 {
                    data.skipBit() // azimuthDirection
                }
                data.skipBit() // isLFE
            }
            if azimuthAngle != 0, azimuthAngle != 180, try data.readBit() { // alsoAddSymmetricPair
                speaker += 1
            }
            speaker += 1
        }
    }

    static func parseSignals3d(_ data: inout BlockBufferBitReader) throws -> Int {
        var numberOfSignals = 0
        let numberOfSignalGroupsInBitstream = try data.readBits(5)
        for _ in 0 ..< numberOfSignalGroupsInBitstream + 1 {
            let signalGroupType = try data.readBits(3)
            let bsNumberOfSignals = try readEscapedIntValue(&data, 5, 8, 16) ?? 0
            numberOfSignals += bsNumberOfSignals + 1
            // Channels or SAOC: differsFromReferenceLayout or saocDmxLayoutPresent.
            if signalGroupType == 0 || signalGroupType == 2, try data.readBit() {
                try skipSpeakerConfig3d(&data)
            }
        }
        return numberOfSignals
    }

    static func skipMpegh3daDecoderConfig(
        _ data: inout BlockBufferBitReader,
        numSignals: Int,
        sbrRatioIndex: Int
    ) throws {
        let numElements = try (readEscapedIntValue(&data, 4, 8, 16) ?? 0) + 1
        data.skipBit() // elementLengthPresent
        for _ in 0 ..< numElements {
            let usacElementType = try data.readBits(2)
            switch usacElementType {
            case 0: // ID_USAC_SCE
                _ = try parseMpegh3daCoreConfig(&data)
                if sbrRatioIndex > 0 {
                    try skipSbrConfig(&data)
                }
            case 1: // ID_USAC_CPE
                if try parseMpegh3daCoreConfig(&data) {
                    data.skipBit() // igfIndependentTiling
                }
                var stereoConfigIndex = 0
                if sbrRatioIndex > 0 {
                    try skipSbrConfig(&data)
                    stereoConfigIndex = try data.readBits(2)
                }
                if stereoConfigIndex > 0 {
                    data.skipBits(6) // bsFreqRes, bsFixedGainDMX
                    let bsTempShapeConfig = try data.readBits(2)
                    data.skipBits(4) // bsDecorrConfig, bsHighRateMode, bsPhaseCoding
                    if try data.readBit() { // bsOttBandsPhasePresent
                        data.skipBits(5) // bsOttBandsPhase
                    }
                    if stereoConfigIndex == 2 || stereoConfigIndex == 3 {
                        data.skipBits(6) // bsResidualBands, bsPseudoLr
                    }
                    if bsTempShapeConfig == 2 {
                        data.skipBit() // bsEnvQuantMode
                    }
                }
                let nBits = Int(floor(log2(Double(numSignals - 1)))) + 1
                let qceIndex = try data.readBits(2)
                if qceIndex > 0, try data.readBit() { // shiftIndex0
                    data.skipBits(nBits) // shiftChannel0
                }
                if try data.readBit() { // shiftIndex1
                    data.skipBits(nBits) // shiftChannel1
                }
                if sbrRatioIndex == 0, qceIndex == 0 {
                    data.skipBit() // lpdStereoIndex
                }
            case 3: // ID_USAC_EXT
                _ = try readEscapedIntValue(&data, 4, 8, 16) // usacExtElementType
                let usacExtElementConfigLength = try readEscapedIntValue(&data, 4, 8, 16) ?? 0
                if try data.readBit() { // usacExtElementDefaultLengthPresent
                    _ = try readEscapedIntValue(&data, 8, 16, 0) // usacExtElementDefaultLength
                }
                data.skipBit() // usacExtElementPayloadFrag
                if usacExtElementConfigLength > 0 {
                    data.skipBits(8 * usacExtElementConfigLength)
                }
            default:
                break
            }
        }
    }

    /// - Returns: Whether enhanced noise filling is on.
    static func parseMpegh3daCoreConfig(_ data: inout BlockBufferBitReader) throws -> Bool {
        data.skipBits(3) // tw_mdct, fullbandLpd, noiseFilling
        let enhancedNoiseFilling = try data.readBit()
        if enhancedNoiseFilling {
            data.skipBits(13)
        }
        return enhancedNoiseFilling
    }

    static func skipSbrConfig(_ data: inout BlockBufferBitReader) throws {
        data.skipBits(3) // harmonicSBR, bs_interTes, bs_pvc
        data.skipBits(8) // dflt_start_freq, dflt_stop_freq
        let dfltHeaderExtra1 = try data.readBit()
        let dfltHeaderExtra2 = try data.readBit()
        if dfltHeaderExtra1 {
            data.skipBits(5) // dflt_freq_scale, dflt_alter_scale, dflt_noise_bands
        }
        if dfltHeaderExtra2 {
            data.skipBits(6)
        }
    }

    /// Reads an `escapedValue()`, or returns `nil` if the data ends before it.
    static func readEscapedIntValue(_ data: inout BlockBufferBitReader, _ bits1: Int, _ bits2: Int, _ bits3: Int) throws -> Int? {
        try readEscapedLongValue(&data, bits1, bits2, bits3).map { Int($0) }
    }

    static func readEscapedLongValue(_ data: inout BlockBufferBitReader, _ bits1: Int, _ bits2: Int, _ bits3: Int) throws -> Int64? {
        guard data.bitsLeft >= bits1 else { return nil }
        var value = try data.readBitsToLong(bits1)
        guard value == (1 << bits1) - 1 else { return value }
        guard data.bitsLeft >= bits2 else { return nil }
        var valueAdd = try data.readBitsToLong(bits2)
        value += valueAdd
        guard valueAdd == (1 << bits2) - 1 else { return value }
        guard data.bitsLeft >= bits3 else { return nil }
        valueAdd = try data.readBitsToLong(bits3)
        return value + valueAdd
    }
}

extension CodecAttributes where Scope == AudioCodec.MPEGH {
    /// Reads an `MHADecoderConfigurationRecord`: configurationVersion (8), mpegh3daProfileLevelIndication (8),
    /// referenceChannelLayout (8), mpegh3daConfigLength (16), then the mpegh3daConfig.
    ///
    /// - Parameter box: The payload of an `mhaC` box, its indices starting at 0.
    init(mhaC box: BlockBufferReader) throws {
        var reader = box
        reader.moveReaderIndex(forwardBy: 1)
        self.init()
        self.profileLevelIndication = try Int(reader.readInt(as: UInt8.self))
        self.referenceChannelLayout = try Int(reader.readInt(as: UInt8.self))
        let length = try Int(reader.readInt(as: UInt16.self))
        self.configuration = try reader.readData(length: length)
    }
}
