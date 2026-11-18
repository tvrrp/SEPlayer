//
//  ChannelLayoutBox.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2026.
//

import AudioToolbox
import CoreAudio
import SEPlayerCommon

/// Reads an ISO channel layout box, `chnl` of ISO/IEC 14496-12, 12.2.4, into the layout of a stream's channels.
///
/// The layout is either one of ISO/IEC 23091-3's ChannelConfigurations, maybe with channels omitted, or a speaker
/// position for each channel.
enum ChannelLayoutBox {
    /// The layout of a `chnl` box for a stream of `format` with `channelCount` channels.
    ///
    /// - Parameter box: The whole box, from its size field.
    /// - Returns: `nil` for a box that can't be read or doesn't describe `channelCount` channels.
    static func channelLayout(box: BlockBufferReader, format: AudioFormatID, channelCount: Int) -> ManagedAudioChannelLayout? {
        try? readLayout(box: box, format: format, channelCount: channelCount)
    }

    private static func readLayout(box: BlockBufferReader, format: AudioFormatID, channelCount: Int) throws -> ManagedAudioChannelLayout {
        let available = box.readableBytes
        guard available >= 12 else { throw AudioConfigError() }
        var bits = BlockBufferBitReader(reader: box)
        let size = try bits.readBits(32)
        guard try bits.readBits(32) == MP4Box.BoxType.chnl.rawValue, size <= available else {
            throw AudioConfigError()
        }
        let version = try bits.readBits(8)
        guard try bits.readBits(24) == 0 else { throw AudioConfigError() } // flags
        switch version {
        case 0 where size >= 14,
             1 where size >= 16: break
        default: throw AudioConfigError()
        }

        // stream_structure: channels only, objects can't be described.
        var channelCount = channelCount
        if version == 0 {
            guard try bits.readBits(8) == channelStructured else { throw AudioConfigError() }
        } else {
            guard try bits.readBits(4) == channelStructured else { throw AudioConfigError() }
            guard try bits.readBits(4) & 0xE == 0 else { throw AudioConfigError() } // format_ordering
            channelCount = try bits.readBits(8) // base_channel_count
        }

        let definedLayout = try bits.readBits(8)
        guard definedLayout != 0 else {
            if version == 1 {
                guard try bits.readBits(8) == channelCount else { throw AudioConfigError() } // layout_channel_count
            }
            let descriptions = try (0 ..< channelCount).map { _ in try readSpeakerPosition(&bits) }
            return collapsed(descriptions)
        }

        let tag: AudioChannelLayoutTag?
        var omittedChannelsOffset: Int?
        if version == 0 {
            tag = standardLayoutTags[definedLayout]
            omittedChannelsOffset = 14
        } else {
            try bits.skip(bits: 4) // reserved
            let channelOrder = try bits.readBits(3)
            if try bits.readBit() { omittedChannelsOffset = 16 }
            switch channelOrder {
            case 0:
                tag = standardLayoutTags[definedLayout]
            case 1 where isoOrderedFormats.contains(format):
                tag = standardLayoutTags[definedLayout]
            case 1:
                guard definedLayout <= 21, let codecTag = codecOrderLayoutTag(definedLayout, format: format) else {
                    throw AudioConfigError()
                }
                tag = codecTag
            default:
                throw AudioConfigError()
            }
        }

        var omittedChannels: UInt64 = 0
        if let omittedChannelsOffset {
            guard size >= omittedChannelsOffset + 8 else { throw AudioConfigError() }
            omittedChannels = try box.getInt(at: box.readerIndex + omittedChannelsOffset, as: UInt64.self)
        }
        // A layout ISO/IEC 23091-3 has no tag for describes no channels.
        guard let tag else { throw AudioConfigError() }
        guard omittedChannels != 0 else {
            guard Int(tag & 0xFFFF) == channelCount else { throw AudioConfigError() }
            return ManagedAudioChannelLayout(tag: tag)
        }

        let full = try AudioFormatProperties.channelLayout(tag: tag)
        let kept = full.channelDescriptions.enumerated().filter { index, _ in
            omittedChannels & omittedChannelBit(index) == 0
        }
        guard kept.count == channelCount else { throw AudioConfigError() }
        return collapsed(kept.map(\.element))
    }

    /// Reads a speaker_position, and the azimuth and elevation an explicit position follows it with.
    private static func readSpeakerPosition(_ bits: inout BlockBufferBitReader) throws -> AudioChannelDescription {
        let position = try bits.readBits(8)
        var description = AudioChannelDescription(mChannelLabel: kAudioChannelLabel_Unknown, mChannelFlags: [], mCoordinates: (0, 0, 0))
        if speakerPositionLabels.indices.contains(position) {
            description.mChannelLabel = speakerPositionLabels[position]
            if positionsByCoordinates.contains(position) {
                description.mChannelLabel = kAudioChannelLabel_UseCoordinates
                description.mChannelFlags = .sphericalCoordinates
                description.mCoordinates = (-0.0, 0, 1)
            }
        } else if position == explicitPosition {
            // Decoders read the azimuth with its bytes swapped; the layout follows them.
            let azimuth = try Int16(bitPattern: UInt16(bits.readBits(16)).byteSwapped)
            let elevation = try Int8(bitPattern: UInt8(bits.readBits(8)))
            description.mChannelLabel = kAudioChannelLabel_UseCoordinates
            description.mChannelFlags = .sphericalCoordinates
            // The box and a channel description count azimuth in opposite directions.
            description.mCoordinates = (Float32(-Int(azimuth)), Float32(elevation), 1)
        }
        return description
    }

    /// The layout of `descriptions`, by its tag when one names the channels.
    private static func collapsed(_ descriptions: [AudioChannelDescription]) -> ManagedAudioChannelLayout {
        // A layout of no channels is still read, as one without descriptions.
        guard !descriptions.isEmpty else {
            return emptyLayout
        }
        let layout = ManagedAudioChannelLayout(channelDescriptions: descriptions)
        guard let tag = try? AudioFormatProperties.tag(for: layout),
              ![0, kAudioChannelLayoutTag_Unknown, kAudioChannelLayoutTag_UseChannelBitmap].contains(tag) else {
            return layout
        }
        return ManagedAudioChannelLayout(tag: tag)
    }

    /// The bit of omitted_channels_map that omits the channel at `index`.
    ///
    /// Decoders test the bit as a signed 32-bit value: the bits of channels 32 and up repeat those of the first 32,
    /// and channel 31's covers all the high bits.
    private static func omittedChannelBit(_ index: Int) -> UInt64 {
        UInt64(bitPattern: Int64(Int32(bitPattern: 1 << UInt32(index & 31))))
    }

    /// The layout of a ChannelConfiguration in the order its codec has the channels.
    private static func codecOrderLayoutTag(_ definedLayout: Int, format: AudioFormatID) -> AudioChannelLayoutTag? {
        let isAC3 = format == kAudioFormatAC3 || format == kAudioFormatEnhancedAC3
        let isEAC3 = format == kAudioFormatEnhancedAC3
        let isFLAC = format == kAudioFormatFLAC
        let isOgg = format == kAudioFormatOpus || format == vorbis
        switch definedLayout {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        case 3 where isAC3 || isOgg: return kAudioChannelLayoutTag_AC3_3_0
        case 3 where isFLAC: return kAudioChannelLayoutTag_MPEG_3_0_A
        case 4 where isAC3: return kAudioChannelLayoutTag_AC3_3_1
        case 5 where isAC3: return kAudioChannelLayoutTag_MPEG_5_0_C
        case 5 where isFLAC: return kAudioChannelLayoutTag_MPEG_5_0_A
        case 6 where isAC3: return kAudioChannelLayoutTag_MPEG_5_1_C
        case 6 where isFLAC: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 7 where isEAC3: return kAudioChannelLayoutTag_EAC3_7_1_B
        case 8: return kAudioChannelLayoutTag_DiscreteInOrder | 2
        case 9: return kAudioChannelLayoutTag_ITU_2_1
        case 10 where isAC3 || isFLAC: return kAudioChannelLayoutTag_ITU_2_2
        case 11 where isEAC3: return kAudioChannelLayoutTag_EAC3_6_1_A
        case 11 where isFLAC: return kAudioChannelLayoutTag_WAVE_6_1
        case 11 where isOgg: return kAudioChannelLayoutTag_Ogg_6_1
        case 12 where isEAC3: return kAudioChannelLayoutTag_EAC3_7_1_A
        case 12 where isFLAC: return kAudioChannelLayoutTag_WAVE_7_1
        case 12 where isOgg: return kAudioChannelLayoutTag_Ogg_7_1
        case 14 where isEAC3: return kAudioChannelLayoutTag_EAC3_7_1_E
        case 21: return kAudioChannelLayoutTag_Binaural
        default: return nil
        }
    }
}

private extension ChannelLayoutBox {
    static let channelStructured = 1
    /// The speaker_position followed by an explicit azimuth and elevation.
    static let explicitPosition = 126
    static let vorbis: AudioFormatID = 0x766F_7262 // 'vorb'

    /// A layout of channel descriptions that has none.
    static var emptyLayout: ManagedAudioChannelLayout {
        let header = [UInt8](repeating: 0, count: ManagedAudioChannelLayout.headerSize)
        let layout = header.withUnsafeBytes { ManagedAudioChannelLayout(layoutBytes: $0) }
        return layout ?? ManagedAudioChannelLayout(tag: kAudioChannelLayoutTag_Unknown)
    }

    /// Formats whose channels are in ISO/IEC 23091-3's order, so that their codec's order is the standard one.
    static let isoOrderedFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatAppleLossless, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
        kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_HE_V2,
    ]

    /// The layouts of ChannelConfiguration 1 to 21 in ISO/IEC 23091-3's order.
    static let standardLayoutTags: [Int: AudioChannelLayoutTag] = [
        1: kAudioChannelLayoutTag_Mono,
        2: kAudioChannelLayoutTag_Stereo,
        3: kAudioChannelLayoutTag_MPEG_3_0_B,
        4: kAudioChannelLayoutTag_MPEG_4_0_B,
        5: kAudioChannelLayoutTag_MPEG_5_0_D,
        6: kAudioChannelLayoutTag_MPEG_5_1_D,
        7: kAudioChannelLayoutTag_MPEG_7_1_B,
        8: kAudioChannelLayoutTag_DiscreteInOrder | 2,
        9: kAudioChannelLayoutTag_ITU_2_1,
        10: kAudioChannelLayoutTag_ITU_2_2,
        11: kAudioChannelLayoutTag_AAC_6_1,
        12: kAudioChannelLayoutTag_AAC_7_1_B,
        13: kAudioChannelLayoutTag_CICP_13,
        14: kAudioChannelLayoutTag_AAC_7_1_C,
        15: kAudioChannelLayoutTag_CICP_15,
        16: kAudioChannelLayoutTag_CICP_16,
        17: kAudioChannelLayoutTag_CICP_17,
        18: kAudioChannelLayoutTag_CICP_18,
        19: kAudioChannelLayoutTag_CICP_19,
        20: kAudioChannelLayoutTag_CICP_20,
        21: kAudioChannelLayoutTag_Binaural,
    ]

    /// The positions that are given as coordinates rather than a label.
    static let positionsByCoordinates: Set<Int> = [39, 40]

    /// The channel labels of speaker_position 0 to 44 of ISO/IEC 23091-3, Table 7.
    static let speakerPositionLabels: [AudioChannelLabel] = [
        kAudioChannelLabel_Left,
        kAudioChannelLabel_Right,
        kAudioChannelLabel_Center,
        kAudioChannelLabel_LFEScreen,
        kAudioChannelLabel_LeftSurround,
        kAudioChannelLabel_RightSurround,
        kAudioChannelLabel_LeftCenter,
        kAudioChannelLabel_RightCenter,
        kAudioChannelLabel_RearSurroundLeft,
        kAudioChannelLabel_RearSurroundRight,
        kAudioChannelLabel_CenterSurround,
        kAudioChannelLabel_LeftSurroundDirect,
        kAudioChannelLabel_RightSurroundDirect,
        kAudioChannelLabel_LeftSideSurround,
        kAudioChannelLabel_RightSideSurround,
        kAudioChannelLabel_LeftWide,
        kAudioChannelLabel_RightWide,
        kAudioChannelLabel_VerticalHeightLeft,
        kAudioChannelLabel_VerticalHeightRight,
        kAudioChannelLabel_VerticalHeightCenter,
        kAudioChannelLabel_LeftTopRear,
        kAudioChannelLabel_RightTopRear,
        kAudioChannelLabel_CenterTopRear,
        kAudioChannelLabel_LeftTopMiddle,
        kAudioChannelLabel_RightTopMiddle,
        kAudioChannelLabel_TopCenterSurround,
        kAudioChannelLabel_LFE2,
        kAudioChannelLabel_LeftBottom,
        kAudioChannelLabel_RightBottom,
        kAudioChannelLabel_CenterBottom,
        kAudioChannelLabel_LeftTopSurround,
        kAudioChannelLabel_RightTopSurround,
        kAudioChannelLabel_Unused,
        kAudioChannelLabel_Unused,
        kAudioChannelLabel_Unused,
        kAudioChannelLabel_Unused,
        kAudioChannelLabel_LFE3,
        kAudioChannelLabel_LeftEdgeOfScreen,
        kAudioChannelLabel_RightEdgeOfScreen,
        kAudioChannelLabel_Unknown,
        kAudioChannelLabel_Unknown,
        kAudioChannelLabel_LeftBackSurround,
        kAudioChannelLabel_RightBackSurround,
        kAudioChannelLabel_BinauralLeft,
        kAudioChannelLabel_BinauralRight,
    ]
}
