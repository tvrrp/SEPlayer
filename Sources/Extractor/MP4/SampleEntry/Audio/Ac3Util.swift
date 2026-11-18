//
//  Ac3Util.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import CoreAudio
import CoreMedia
import SEPlayerCommon

/// Reads the AC-3 and E-AC-3 decoder configurations of ETSI TS 102 366 Annex F: the `dac3` and `dec3` boxes.
enum Ac3Util {
    /// The samples of a frame of either.
    static let samplesPerFrame: UInt32 = 1536

    private static let sampleRates: [Double] = [48000, 44100, 32000]
    /// The full-bandwidth channels of each audio coding mode.
    private static let channelCounts = [2, 1, 2, 3, 3, 4, 4, 5]

    // MARK: - AC-3

    /// The stream description of a `dac3` box.
    ///
    /// - Parameter box: The whole box, from its size field.
    static func ac3StreamDescription(dac3 box: BlockBufferReader) -> AudioStreamBasicDescription? {
        guard let config = Ac3Config(box: box) else { return nil }
        return AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: kAudioFormatAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: samplesPerFrame,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCounts[config.audioCodingMode] + (config.hasLowFrequencyEffects ? 1 : 0)),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// The channel layout of a `dac3` box, for decoders that don't tell theirs.
    ///
    /// - Parameter box: The whole box, from its size field.
    static func ac3ChannelLayout(dac3 box: BlockBufferReader) -> ManagedAudioChannelLayout? {
        guard let config = Ac3Config(box: box) else { return nil }
        let lfe = config.hasLowFrequencyEffects
        let tag: AudioChannelLayoutTag = switch config.audioCodingMode {
        case 1: lfe ? kAudioChannelLayoutTag_AC3_1_0_1 : kAudioChannelLayoutTag_Mono
        case 3: lfe ? kAudioChannelLayoutTag_AC3_3_0_1 : kAudioChannelLayoutTag_AC3_3_0
        case 4: lfe ? kAudioChannelLayoutTag_AC3_2_1_1 : kAudioChannelLayoutTag_DVD_2
        case 5: lfe ? kAudioChannelLayoutTag_AC3_3_1_1 : kAudioChannelLayoutTag_AC3_3_1
        case 6: lfe ? kAudioChannelLayoutTag_DVD_18 : kAudioChannelLayoutTag_DVD_3
        case 7: lfe ? kAudioChannelLayoutTag_MPEG_5_1_C : kAudioChannelLayoutTag_MPEG_5_0_C
        // Dual mono and stereo.
        default: lfe ? kAudioChannelLayoutTag_DVD_4 : kAudioChannelLayoutTag_Stereo
        }
        return ManagedAudioChannelLayout(tag: tag)
    }

    private struct Ac3Config {
        let sampleRate: Double
        let audioCodingMode: Int
        let hasLowFrequencyEffects: Bool

        /// fscod (2), bsid (5), bsmod (3), acmod (3), lfeon (1), bit_rate_code (5), reserved (5).
        init?(box: BlockBufferReader) {
            guard let first = try? box.getInt(at: 8, as: UInt8.self),
                  let second = try? box.getInt(at: 9, as: UInt8.self),
                  let third = try? box.getInt(at: 10, as: UInt8.self) else {
                return nil
            }
            let sampleRateCode = Int(first >> 6)
            guard sampleRateCode < 3 else { return nil }
            let bitRateCode = Int((second & 0x03) << 3 | third >> 5)
            guard bitRateCode <= 18 else { return nil }
            sampleRate = sampleRates[sampleRateCode]
            audioCodingMode = Int((second >> 3) & 0x07)
            hasLowFrequencyEffects = second & 0x04 != 0
        }
    }

    // MARK: - E-AC-3

    /// The stream description and channel layout of a `dec3` box: the highest sample rate of its independent
    /// substreams, and the channels of the last one with its dependent substreams.
    ///
    /// - Parameter box: The whole box, from its size field.
    static func eac3Configuration(dec3 box: BlockBufferReader) -> (AudioStreamBasicDescription, ManagedAudioChannelLayout)? {
        // data_rate (13), num_ind_sub (3), then each independent substream.
        guard box.readableBytes > 12, var reader = try? box.slice(from: 9),
              let independentSubstreamCount = try? Int(reader.readInt(as: UInt8.self) & 0x07) + 1 else {
            return nil
        }
        var sampleRate = 0.0
        var labels: [AudioChannelLabel] = []

        for _ in 0 ..< independentSubstreamCount {
            // fscod (2), bsid (5), reserved (1), asvc (1), bsmod (3), acmod (3), lfeon (1), reserved (3),
            // num_dep_sub (4), then chan_loc (9) with dependent substreams or reserved (1).
            guard let first = try? reader.readInt(as: UInt8.self),
                  let second = try? reader.readInt(as: UInt8.self),
                  let third = try? reader.readInt(as: UInt8.self) else {
                return nil
            }
            let sampleRateCode = Int(first >> 6)
            guard sampleRateCode < 3 else { return nil }
            sampleRate = max(sampleRate, sampleRates[sampleRateCode])
            let audioCodingMode = Int((second >> 1) & 0x07)
            labels = channelLabels(audioCodingMode: audioCodingMode)
            if second & 0x01 != 0 {
                labels.append(kAudioChannelLabel_LFEScreen)
            }
            guard (third >> 1) & 0x0F != 0 else { continue }
            guard let fourth = try? reader.readInt(as: UInt8.self) else {
                return nil
            }
            let channelLocations = Int(third & 0x01) << 8 | Int(fourth)
            labels += dependentSubstreamLabels(channelLocations: channelLocations, audioCodingMode: audioCodingMode)
        }

        let description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatEnhancedAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: samplesPerFrame,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(labels.count),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let described = ManagedAudioChannelLayout(labels: labels)
        let layout = (try? AudioFormatProperties.tag(for: described)).map(ManagedAudioChannelLayout.init(tag:)) ?? described
        return (description, layout)
    }

    private static func channelLabels(audioCodingMode: Int) -> [AudioChannelLabel] {
        switch audioCodingMode {
        case 1: [kAudioChannelLabel_Center]
        case 3: [kAudioChannelLabel_Left, kAudioChannelLabel_Center, kAudioChannelLabel_Right]
        case 4: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_CenterSurround]
        case 5: [kAudioChannelLabel_Left, kAudioChannelLabel_Center, kAudioChannelLabel_Right, kAudioChannelLabel_CenterSurround]
        case 6: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        case 7: [
                kAudioChannelLabel_Left,
                kAudioChannelLabel_Center,
                kAudioChannelLabel_Right,
                kAudioChannelLabel_LeftSurround,
                kAudioChannelLabel_RightSurround,
            ]
        // Dual mono and stereo.
        default: [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        }
    }

    /// The channels the dependent substreams add, by the bits of chan_loc.
    private static func dependentSubstreamLabels(channelLocations: Int, audioCodingMode: Int) -> [AudioChannelLabel] {
        var labels: [AudioChannelLabel] = []
        func has(_ bit: Int) -> Bool { channelLocations & (1 << bit) != 0 }
        if has(0) { labels += [kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter] }
        if has(1) { labels += [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight] }
        // A centre surround the independent substream already has isn't added twice.
        if has(2), audioCodingMode != 4, audioCodingMode != 5 { labels.append(kAudioChannelLabel_CenterSurround) }
        if has(3) { labels.append(kAudioChannelLabel_TopCenterSurround) }
        if has(4) { labels += [kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect] }
        if has(5) { labels += [kAudioChannelLabel_LeftWide, kAudioChannelLabel_RightWide] }
        if has(6) { labels += [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight] }
        if has(7) { labels.append(kAudioChannelLabel_VerticalHeightCenter) }
        if has(8) { labels.append(kAudioChannelLabel_LFE2) }
        return labels
    }
}
