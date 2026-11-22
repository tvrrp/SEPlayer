//
//  AudioSpecificConfig.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2026.
//

import Foundation
import SEPlayerCommon

/// An AudioSpecificConfig of ISO/IEC 14496-3, 1.6.2.1: the decoder config of an MPEG-4 audio stream.
///
/// Reads AAC Main, LC, SSR, LTP, LD and ELD with their SBR and parametric stereo extensions, MPEG-1/2 audio layers
/// and USAC.
struct AudioSpecificConfig {
    /// The rates of samplingFrequencyIndex 0 to 12.
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    /// The samplingFrequencyIndex followed by an explicit 24-bit frequency.
    static let explicitSampleRateIndex = 15

    /// The audio object type of the core coder; that of SBR or parametric stereo is replaced by the one it extends.
    let audioObjectType: Int
    /// The rate of the core coder, which SBR may double.
    let sampleRate: Int
    let channelConfiguration: Int
    /// Whether spectral band replication doubles the rate of the core, signalled explicitly or after the config.
    let hasSpectralBandReplication: Bool
    /// The rate SBR gives the output, when the config tells it.
    let extensionSampleRate: Int?
    /// Whether parametric stereo makes stereo of a mono core.
    let hasParametricStereo: Bool
    /// Whether frames are 960 or 480 samples rather than 1024 or 512.
    let hasShortFrames: Bool
    let programConfig: ProgramConfigElement?
    let usacConfig: UsacConfig?

    /// The channels of the core coder: of channelConfiguration, or of the program config element.
    var channelCount: Int? {
        guard channelConfiguration != 0 else {
            return programConfig?.channelCount
        }
        return Self.configurationChannelCounts[channelConfiguration]
    }

    /// The samples of a frame.
    var frameLength: Int? {
        switch audioObjectType {
        case 1 ... 4: hasShortFrames ? 960 : 1024
        case Self.lowDelay,
             Self.enhancedLowDelay: hasShortFrames ? 480 : 512
        case Self.unifiedSpeechAndAudio: usacConfig.map { Int($0.framesPerPacket) }
        default: nil
        }
    }

    /// Reads the config that fills `reader`, the payload of a DecoderSpecificInfo.
    init(reader: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: reader)
        try self.init(bits: &bits, isLastInData: true)
    }

    /// Reads a config from `bits`, which end up after it.
    ///
    /// - Parameter isLastInData: Whether the config is all that is left of `bits`, so that what follows it is the
    ///   extension that announces SBR. Other data follows a config that is part of a bitstream, as in LATM.
    init(bits: inout BlockBufferBitReader, isLastInData: Bool) throws {
        let start = bits.position
        var objectType = try Self.readAudioObjectType(&bits)
        sampleRate = try Self.readSampleRate(&bits)
        guard sampleRate != 0 else { throw AudioConfigError() }
        var channelConfiguration = try bits.readBits(4)

        // Explicit SBR, and parametric stereo, which always comes with SBR.
        var hasSbr = false
        var hasParametricStereo = false
        var extensionSampleRate: Int?
        if objectType == Self.spectralBandReplication || objectType == Self.parametricStereo {
            hasSbr = true
            hasParametricStereo = objectType == Self.parametricStereo
            let rate = try Self.readSampleRate(&bits)
            try Self.checkExtensionSampleRate(rate, sampleRate: sampleRate)
            extensionSampleRate = rate
            objectType = try Self.readAudioObjectType(&bits)
        }

        var hasShortFrames = false
        var programConfig: ProgramConfigElement?
        var usacConfig: UsacConfig?
        switch objectType {
        case 1,
             2,
             3,
             4,
             Self.lowDelay:
            hasShortFrames = try bits.readBit()
            if try bits.readBit() { try bits.skip(bits: 14) } // dependsOnCoreCoder, coreCoderDelay
            let hasExtension = try bits.readBit()
            if channelConfiguration == 0 {
                let element = try ProgramConfigElement(reader: &bits, configStart: start)
                guard element.sampleRate == sampleRate else {
                    throw AudioConfigError()
                }
                programConfig = element
            }
            if hasExtension {
                if objectType == Self.lowDelay { try bits.skip(bits: 3) } // the resilience flags
                try bits.skip(bits: 1) // extensionFlag3
            }
        case Self.enhancedLowDelay:
            hasShortFrames = try Self.readEnhancedLowDelayConfig(&bits, channelConfiguration: channelConfiguration)
        case Self.mpegLayer1,
             Self.mpegLayer2,
             Self.mpegLayer3:
            try bits.skip(bits: 1) // MPEG_1_2_SpecificConfig: extension
        case Self.unifiedSpeechAndAudio:
            let config = try UsacConfig(reader: &bits)
            // Stereo made from a downmix by MPEG Surround is stereo output.
            if config.hasStereoUpmix && channelConfiguration == 1 { channelConfiguration = 2 }
            usacConfig = config
        default:
            throw AudioConfigError()
        }
        if objectType == Self.lowDelay || objectType == Self.enhancedLowDelay {
            if try bits.readBits(2) == 3 { try bits.skip(bits: 1) } // epConfig, directMapping
        }

        // Implicit SBR and parametric stereo, signalled after the config for decoders that skip it.
        var announcesSbr = false
        if isLastInData, [1, 2, 3, 4, Self.lowDelay, Self.enhancedLowDelay].contains(objectType), bits.bitsLeft > 10 {
            announcesSbr = try bits.readBits(11) == Self.sbrSyncExtension
        }
        if announcesSbr, !hasSbr, bits.bitsLeft > 4 {
            guard (1 ... 4).contains(objectType) else {
                throw AudioConfigError()
            }
            let extensionType = try Self.readAudioObjectType(&bits)
            guard extensionType != Self.bitSlicedArithmeticCoding else {
                throw AudioConfigError()
            }
            if extensionType == Self.spectralBandReplication {
                if try bits.readBit() {
                    let rate = try Self.readSampleRate(&bits)
                    try Self.checkExtensionSampleRate(rate, sampleRate: sampleRate)
                    hasSbr = true
                    extensionSampleRate = rate
                }
                if bits.bitsLeft > 11, try bits.readBits(11) == Self.parametricStereoSyncExtension {
                    hasParametricStereo = try bits.readBit()
                }
            }
        }

        audioObjectType = objectType
        self.channelConfiguration = channelConfiguration
        hasSpectralBandReplication = hasSbr
        self.extensionSampleRate = extensionSampleRate
        self.hasParametricStereo = hasParametricStereo
        self.hasShortFrames = hasShortFrames
        self.programConfig = programConfig
        self.usacConfig = usacConfig
    }

    /// Reads an ELDSpecificConfig of ISO/IEC 14496-3, 4.6.20.
    ///
    /// - Returns: frameLengthFlag.
    private static func readEnhancedLowDelayConfig(
        _ bits: inout BlockBufferBitReader,
        channelConfiguration: Int
    ) throws -> Bool {
        let hasShortFrames = try bits.readBit()
        // Error resilience can't be decoded.
        guard try bits.readBits(3) == 0 else { throw AudioConfigError() }
        if try bits.readBit() {
            try bits.skip(bits: 2) // ldSbrSamplingRate, ldSbrCrcFlag
            let headerCount = switch channelConfiguration {
            case 1,
                 2: 1
            case 3: 2
            case 4,
                 5,
                 6: 3
            case 7: 4
            default: 0
            }
            for _ in 0 ..< headerCount {
                try bits.skip(bits: 14) // bs_amp_res, bs_start_freq, bs_stop_freq, bs_xover_band, bs_reserved
                let hasExtra1 = try bits.readBit()
                let hasExtra2 = try bits.readBit()
                if hasExtra1 { try bits.skip(bits: 5) }
                if hasExtra2 { try bits.skip(bits: 6) }
            }
        }
        while bits.bitsLeft >= 8 {
            let extensionType = try bits.readBits(4)
            guard extensionType != 0 else { break } // ELDEXT_TERM
            var length = try bits.readBits(4)
            if length == 15 { length += try bits.readBits(8) }
            if length == 15 + 255 { length += try bits.readBits(16) }
            try bits.skip(bits: 8 * length)
        }
        return hasShortFrames
    }

    private static func readAudioObjectType(_ bits: inout BlockBufferBitReader) throws -> Int {
        var objectType = try bits.readBits(5)
        if objectType == 31 { objectType = try 32 + (bits.readBits(6)) }
        // Types 10 and 11 are reserved.
        return objectType == 10 || objectType == 11 ? 0 : objectType
    }

    /// Reads a samplingFrequencyIndex and the frequency it may announce.
    ///
    /// - Returns: The rate, or 0 for a reserved index.
    private static func readSampleRate(_ bits: inout BlockBufferBitReader) throws -> Int {
        let index = try bits.readBits(4)
        if index == explicitSampleRateIndex {
            return try bits.readBits(24)
        }
        return sampleRates.indices.contains(index) ? sampleRates[index] : 0
    }

    /// Checks that SBR doubles the core rate or keeps it.
    private static func checkExtensionSampleRate(_ rate: Int, sampleRate: Int) throws {
        guard rate == sampleRate || rate == 2 * sampleRate else {
            throw AudioConfigError()
        }
    }
}

/// A decoder config that can't be read or describes a stream the system can't decode.
struct AudioConfigError: Error {}

extension BlockBufferBitReader {
    /// Skips `count` bits, throwing when fewer are left.
    mutating func skip(bits count: Int) throws {
        guard count >= 0, bitsLeft >= count else {
            throw BlockBufferReaderErrors(.outOfBounds)
        }
        skipBits(count)
    }

    /// Reads an escapedValue() of ISO/IEC 23003-3, 5.2: a field that grows by a second and a third field when the
    /// first ones are all ones.
    mutating func readEscapedValue(_ first: Int, _ second: Int, _ third: Int) throws -> Int {
        var value = try readBits(first)
        guard value == (1 << first) - 1 else { return value }
        let secondValue = try readBits(second)
        value += secondValue
        guard secondValue == (1 << second) - 1 else { return value }
        return try value + readBits(third)
    }
}

private extension AudioSpecificConfig {
    static let spectralBandReplication = 5
    static let bitSlicedArithmeticCoding = 22
    static let lowDelay = 23
    static let parametricStereo = 29
    static let enhancedLowDelay = 39
    static let mpegLayer1 = 32
    static let mpegLayer2 = 33
    static let mpegLayer3 = 34
    static let mpegLayers: Set<Int> = [mpegLayer1, mpegLayer2, mpegLayer3]
    static let unifiedSpeechAndAudio = 42
    /// The syncExtensionType that announces SBR, and the one that then announces parametric stereo.
    static let sbrSyncExtension = 0x2B7
    static let parametricStereoSyncExtension = 0x548

    /// The channels of channelConfiguration; the others name none.
    static let configurationChannelCounts = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8, 11: 7, 12: 8, 14: 8]
}

extension CodecAttributes where Scope == AudioCodec.AAC {
    /// The attributes of an AudioSpecificConfig, which decoders take as it is.
    ///
    /// - Parameter reader: The config, the payload of a DecoderSpecificInfo.
    init(audioSpecificConfig reader: BlockBufferReader) throws {
        let config = try AudioSpecificConfig(reader: reader)
        self.init()
        self.objectType = AudioCodec.AAC.ObjectType(rawValue: config.audioObjectType)
        self.coreSampleRate = config.sampleRate
        self.extensionSampleRate = config.extensionSampleRate
        self.channelConfiguration = config.channelConfiguration
        self.hasSpectralBandReplication = config.hasSpectralBandReplication
        self.hasParametricStereo = config.hasParametricStereo
        self.frameLength = config.frameLength
        self.audioSpecificConfig = try reader.readableData()
    }
}
