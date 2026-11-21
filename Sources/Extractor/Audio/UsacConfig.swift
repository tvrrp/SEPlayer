//
//  UsacConfig.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2026.
//

import SEPlayerCommon

/// A UsacConfig of ISO/IEC 23003-3, 5.2: the config of USAC (xHE-AAC) in an AudioSpecificConfig.
struct UsacConfig {
    let sampleRate: Int
    /// coreSbrFrameLengthIndex: the core's frame length and the ratio SBR resamples it by.
    let coreSbrFrameLengthIndex: Int
    /// Whether a channel pair element decodes a downmix to stereo with MPEG Surround (stereoConfigIndex above 0).
    let hasStereoUpmix: Bool

    /// The output frames of each access unit.
    var framesPerPacket: UInt32 {
        Self.framesPerPacket[coreSbrFrameLengthIndex]
    }

    /// Reads the config at the reader's position, all of it: a config that doesn't end within the reader fails.
    init(reader bits: inout BlockBufferBitReader) throws {
        let rateIndex = try bits.readBits(5)
        if rateIndex == 31 {
            sampleRate = try bits.readBits(24)
        } else {
            sampleRate = Self.sampleRates[rateIndex]
        }
        guard sampleRate != 0 else { throw AudioConfigError() }
        coreSbrFrameLengthIndex = try bits.readBits(3)
        guard coreSbrFrameLengthIndex < Self.framesPerPacket.count else { throw AudioConfigError() }
        let hasSbr = coreSbrFrameLengthIndex >= 2

        // UsacChannelConfig: bsOutputChannelPos of each channel.
        if try bits.readBits(5) == 0 {
            let channelCount = try bits.readEscapedValue(5, 8, 16)
            try bits.skip(bits: 5 * channelCount)
        }

        var hasStereoUpmix = false
        let elementCount = try bits.readEscapedValue(4, 8, 16) + 1
        for _ in 0 ..< elementCount {
            switch try bits.readBits(2) {
            case Self.singleChannelElement:
                try bits.skip(bits: 2) // tw_mdct, noiseFilling
                if hasSbr { try Self.skipSbrConfig(&bits) }
            case Self.channelPairElement:
                try bits.skip(bits: 2) // tw_mdct, noiseFilling
                if hasSbr {
                    try Self.skipSbrConfig(&bits)
                    let stereoConfigIndex = try bits.readBits(2)
                    if stereoConfigIndex > 0 {
                        try Self.skipMps212Config(&bits, stereoConfigIndex: stereoConfigIndex)
                        hasStereoUpmix = true
                    }
                }
            case Self.lfeElement:
                break
            default:
                try Self.skipExtensionElementConfig(&bits)
            }
        }

        if try bits.readBit() {
            let extensionCount = try bits.readEscapedValue(2, 4, 8) + 1
            for _ in 0 ..< extensionCount {
                let type = try bits.readEscapedValue(4, 8, 16)
                let length = try bits.readEscapedValue(4, 8, 16)
                if type == Self.fillExtension {
                    for _ in 0 ..< length {
                        guard try bits.readBits(8) == Self.fillByte else { throw AudioConfigError() }
                    }
                } else {
                    try bits.skip(bits: 8 * length)
                }
            }
        }
        self.hasStereoUpmix = hasStereoUpmix
    }

    /// Skips an SbrConfig: harmonicSBR, bs_interTes, bs_pvc and the SbrDfltHeader.
    private static func skipSbrConfig(_ bits: inout BlockBufferBitReader) throws {
        try bits.skip(bits: 3 + 8) // the three flags, dflt_start_freq, dflt_stop_freq
        let hasExtra1 = try bits.readBit()
        let hasExtra2 = try bits.readBit()
        if hasExtra1 { try bits.skip(bits: 5) }
        if hasExtra2 { try bits.skip(bits: 6) }
    }

    private static func skipMps212Config(_ bits: inout BlockBufferBitReader, stereoConfigIndex: Int) throws {
        try bits.skip(bits: 3 + 3) // bsFreqRes, bsFixedGainDMX
        let temporalShapeConfig = try bits.readBits(2)
        try bits.skip(bits: 2 + 1) // bsDecorrConfig, bsHighRateMode
        try bits.skip(bits: 1) // bsPhaseCoding
        if try bits.readBit() { try bits.skip(bits: 5) } // bsOttBandsPhase
        if stereoConfigIndex > 1 { try bits.skip(bits: 5 + 1) } // bsResidualBands, bsPseudoLr
        if temporalShapeConfig == 2 { try bits.skip(bits: 1) } // bsEnvQuantMode
    }

    /// Skips a UsacExtElementConfig, whose payload its length gives.
    private static func skipExtensionElementConfig(_ bits: inout BlockBufferBitReader) throws {
        _ = try bits.readEscapedValue(4, 8, 16) // usacExtElementType
        let length = try bits.readEscapedValue(4, 8, 16)
        if try bits.readBit() { _ = try bits.readEscapedValue(8, 16, 0) } // usacExtElementDefaultLength
        try bits.skip(bits: 1) // usacExtElementPayloadFrag
        try bits.skip(bits: 8 * length)
    }
}

private extension UsacConfig {
    static let singleChannelElement = 0
    static let channelPairElement = 1
    static let lfeElement = 2
    static let fillExtension = 0
    static let fillByte = 0xA5

    /// The rates of usacSamplingFrequencyIndex 0 to 30; 0 for the reserved ones.
    static let sampleRates = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0,
        57600, 51200, 40000, 38400, 34150, 28800, 25600, 20000, 19200, 17075, 14400, 12800, 9600, 0, 0, 0,
    ]

    /// The output frame length of coreSbrFrameLengthIndex 0 to 4.
    static let framesPerPacket: [UInt32] = [768, 1024, 2048, 2048, 4096]
}
