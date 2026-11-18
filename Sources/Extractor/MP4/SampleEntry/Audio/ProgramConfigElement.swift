//
//  ProgramConfigElement.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2026.
//

import AudioToolbox
import CoreAudio
import SEPlayerCommon

/// A program_config_element of ISO/IEC 14496-3, 4.4.1.1: the channel elements of AAC whose channelConfiguration is 0.
struct ProgramConfigElement: Hashable {
    /// The element kinds of each group, `true` for a channel pair element, `false` for a single channel element.
    let front: [Bool]
    let side: [Bool]
    let back: [Bool]
    let lfeCount: Int
    /// The rate of sampling_frequency_index; 0 for a reserved index.
    let sampleRate: Int

    /// The layout of the elements, for the arrangements that name one.
    var channelLayoutTag: AudioChannelLayoutTag? {
        Self.layoutTags[Arrangement(front: front, side: side, back: back, lfeCount: lfeCount)]
    }

    /// Reads the element at the reader's position.
    ///
    /// - Parameter configStart: Where the AudioSpecificConfig starts, which the byte alignment counts from.
    init(reader: inout BlockBufferBitReader, configStart: Int) throws {
        try reader.skip(bits: 4) // element_instance_tag
        try reader.skip(bits: 2) // object_type
        let rateIndex = try reader.readBits(4)
        // An explicit frequency has no place here.
        guard rateIndex != AudioSpecificConfig.explicitSampleRateIndex else {
            throw AudioConfigError()
        }
        let rates = AudioSpecificConfig.sampleRates
        sampleRate = rates.indices.contains(rateIndex) ? rates[rateIndex] : 0

        let frontCount = try reader.readBits(4)
        let sideCount = try reader.readBits(4)
        let backCount = try reader.readBits(4)
        lfeCount = try reader.readBits(2)
        let associatedDataCount = try reader.readBits(3)
        let couplingCount = try reader.readBits(4)
        if try reader.readBit() { try reader.skip(bits: 4) } // mono_mixdown_element_number
        if try reader.readBit() { try reader.skip(bits: 4) } // stereo_mixdown_element_number
        if try reader.readBit() { try reader.skip(bits: 3) } // matrix_mixdown_idx, pseudo_surround_enable

        front = try Self.readElements(count: frontCount, reader: &reader)
        side = try Self.readElements(count: sideCount, reader: &reader)
        back = try Self.readElements(count: backCount, reader: &reader)
        try reader.skip(bits: 4 * lfeCount)
        try reader.skip(bits: 4 * associatedDataCount)
        try reader.skip(bits: 5 * couplingCount) // cc_e_is_ind_sw, valid_cc_e_tag_select

        let misalignment = (reader.position - configStart) % 8
        if misalignment != 0 { try reader.skip(bits: 8 - misalignment) }
        let commentLength = try reader.readBits(8)
        try reader.skip(bits: 8 * commentLength)
    }

    /// Reads the is_cpe flag and element tag of each element of a group.
    private static func readElements(count: Int, reader: inout BlockBufferBitReader) throws -> [Bool] {
        try (0 ..< count).map { _ in
            let isPair = try reader.readBit()
            try reader.skip(bits: 4) // element_tag_select
            return isPair
        }
    }
}

private extension ProgramConfigElement {
    /// The groups of elements, as a key of the layouts.
    struct Arrangement: Hashable {
        let front: [Bool]
        let side: [Bool]
        let back: [Bool]
        let lfeCount: Int
    }

    static let single = false
    static let pair = true

    /// The arrangements that name a layout. Any other arrangement leaves the channels without one.
    static let layoutTags: [Arrangement: AudioChannelLayoutTag] = [
        Arrangement(front: [single], side: [], back: [], lfeCount: 0): kAudioChannelLayoutTag_Mono,
        Arrangement(front: [pair], side: [], back: [], lfeCount: 0): kAudioChannelLayoutTag_Stereo,
        Arrangement(front: [single, single], side: [], back: [], lfeCount: 0): kAudioChannelLayoutTag_Stereo,
        Arrangement(front: [pair], side: [], back: [pair], lfeCount: 0): kAudioChannelLayoutTag_Quadraphonic,
        Arrangement(front: [single, pair], side: [], back: [], lfeCount: 0): kAudioChannelLayoutTag_AAC_3_0,
        Arrangement(front: [single, pair], side: [], back: [single], lfeCount: 0): kAudioChannelLayoutTag_AAC_4_0,
        Arrangement(front: [single, pair], side: [], back: [pair], lfeCount: 0): kAudioChannelLayoutTag_AAC_5_0,
        Arrangement(front: [single, pair], side: [], back: [pair], lfeCount: 1): kAudioChannelLayoutTag_AAC_5_1,
        Arrangement(front: [single, pair], side: [], back: [pair, single], lfeCount: 0): kAudioChannelLayoutTag_AAC_6_0,
        Arrangement(front: [single, pair], side: [pair], back: [single], lfeCount: 0): kAudioChannelLayoutTag_AAC_6_0,
        Arrangement(front: [single, pair], side: [], back: [pair, single], lfeCount: 1): kAudioChannelLayoutTag_AAC_6_1,
        Arrangement(front: [single, pair], side: [pair], back: [single], lfeCount: 1): kAudioChannelLayoutTag_AAC_6_1,
        Arrangement(front: [single, pair], side: [pair], back: [pair], lfeCount: 0): kAudioChannelLayoutTag_AAC_7_0,
        Arrangement(front: [single, pair], side: [pair], back: [pair], lfeCount: 1): kAudioChannelLayoutTag_AAC_7_1,
        Arrangement(front: [single, pair], side: [], back: [pair, pair], lfeCount: 1): kAudioChannelLayoutTag_AAC_7_1_B,
        Arrangement(front: [single, pair, pair], side: [], back: [pair], lfeCount: 1): kAudioChannelLayoutTag_AAC_7_1_C,
        Arrangement(front: [single, pair], side: [pair], back: [pair, single], lfeCount: 0): kAudioChannelLayoutTag_AAC_Octagonal,
    ]
}
