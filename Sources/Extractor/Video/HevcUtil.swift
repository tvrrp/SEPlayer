//
//  HevcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.container.NalUnitUtil
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation
import SEPlayerCommon

/// Reads the HEVC decoder configuration of ISO/IEC 14496-15, 8.3.3, the `hvcC` box, and the parameter sets and SEI
/// messages of H.265 it carries.
enum HevcUtil {
    /// The NAL unit types of H.265, table 7-1.
    /// RASL_R: the last of the types of slices that aren't random access points.
    static let lastTrailingOrLeadingSliceType = 9
    /// BLA_W_LP: the first of the types of random access points.
    static let firstRandomAccessPointType = 16
    /// CRA_NUT: the last of the types of random access points.
    static let lastRandomAccessPointType = 21
    static let videoParameterSetType = 32
    static let sequenceParameterSetType = 33
    static let pictureParameterSetType = 34
    static let accessUnitDelimiterType = 35
    static let prefixSEIType = 39
    static let suffixSEIType = 40
    static let unspecifiedType = 48

    // MARK: - Profile, tier and level

    /// The general profile, tier and level of a stream, as its configuration record and its parameter sets tell them.
    struct ProfileTierLevel {
        let profileSpace: Int
        let isHighTier: Bool
        let profileIdc: Int
        /// general_profile_compatibility_flag, the flag of profile 0 in the lowest bit.
        let compatibilityFlags: UInt32
        /// The six bytes of the constraint flags.
        let constraintBytes: [UInt8]
        let levelIdc: Int

        /// The codec string of RFC 6381, as ISO/IEC 14496-15 Annex E builds it, such as `hvc1.2.4.L153.B0`.
        ///
        /// - Parameter sampleEntryType: `hvc1` or `hev1`, which starts the string.
        func codecs(sampleEntryType: MP4Box.BoxType) -> String {
            // Trailing zero constraint bytes are left out.
            let constraintByteCount = (constraintBytes.lastIndex { $0 != 0 } ?? -1) + 1
            var parts = [
                sampleEntryType.rawValue.fourCharacterCode,
                "\(["", "A", "B", "C"][profileSpace])\(profileIdc)",
                String(compatibilityFlags, radix: 16, uppercase: true),
                "\(isHighTier ? "H" : "L")\(levelIdc)",
            ]
            parts += constraintBytes.prefix(constraintByteCount).map { String($0, radix: 16, uppercase: true) }
            return parts.joined(separator: ".")
        }
    }

    /// The NAL units of an `hvcC` box, each whole from its header, by type in the order of the box.
    ///
    /// - Parameter hvcC: The payload of the box, its indices starting at 0.
    static func nalUnits(hvcC: BlockBufferReader) -> [(type: Int, units: [BlockBufferReader])]? {
        do {
            var reader = try hvcC.slice(from: 22)
            let arrayCount = try Int(reader.readInt(as: UInt8.self))
            var arrays: [(Int, [BlockBufferReader])] = []
            for _ in 0 ..< arrayCount {
                let type = try Int(reader.readInt(as: UInt8.self) & 0x3F)
                let count = try Int(reader.readInt(as: UInt16.self))
                var units: [BlockBufferReader] = []
                for _ in 0 ..< count {
                    let length = try Int(reader.readInt(as: UInt16.self))
                    try units.append(reader.readSlice(length: length))
                }
                arrays.append((type, units))
            }
            return arrays
        } catch {
            return nil
        }
    }

    /// The first NAL unit of `type`.
    static func firstNalUnit(of type: Int, in arrays: [(type: Int, units: [BlockBufferReader])]) -> BlockBufferReader? {
        arrays.first { $0.type == type && !$0.units.isEmpty }?.units.first
    }

    // MARK: - Sequence parameter set

    /// What a sequence parameter set of H.265, 7.3.2.2, tells of its pictures.
    struct SequenceParameterSet {
        /// The number of temporal sub-layers.
        let maxSubLayers: Int
        let isTemporalIDNested: Bool
        let profileTierLevel: ProfileTierLevel
        let chromaFormatIdc: Int
        /// The size of the pictures, inside the conformance window.
        let width: Int
        let height: Int
        let bitDepthLuma: Int
        let bitDepthChroma: Int
        /// The most pictures that come before a picture in decode order and after it in output order.
        let maxNumReorderPics: Int
        let vui: VideoUsabilityInformation?

        /// Whether the pictures are fields, as the VUI tells.
        var isInterlaced: Bool { vui?.fieldSequence == true }

        /// The width of a pixel over its height, as the VUI tells, or 1.
        var pixelWidthHeightRatio: Float {
            guard let ratio = vui?.sampleAspectRatio, ratio.horizontal > 0, ratio.vertical > 0 else {
                return 1
            }
            return Float(ratio.horizontal) / Float(ratio.vertical)
        }

        /// - Parameter nalUnit: The whole NAL unit, from its two-byte header, with emulation prevention bytes.
        init(nalUnit: BlockBufferReader) throws {
            let view = BlockBufferView(nalUnit)
            var data = try ParsableNalUnitBitArray(data: view, offset: view.startIndex + 2, limit: view.endIndex)
            try data.skipBits(4) // sps_video_parameter_set_id
            let maxSubLayersMinus1 = try data.readBits(3)
            maxSubLayers = maxSubLayersMinus1 + 1
            isTemporalIDNested = try data.readBit()
            profileTierLevel = try HevcUtil.readProfileTierLevel(&data, maxSubLayersMinus1: maxSubLayersMinus1)
            _ = try data.readUnsignedExpGolombCodedInt() // sps_seq_parameter_set_id
            let chromaFormatIdc = try data.readUnsignedExpGolombCodedInt()
            self.chromaFormatIdc = chromaFormatIdc
            var hasSeparateColourPlanes = false
            if chromaFormatIdc == 3 {
                hasSeparateColourPlanes = try data.readBit()
            }
            var width = try data.readUnsignedExpGolombCodedInt() // pic_width_in_luma_samples
            var height = try data.readUnsignedExpGolombCodedInt() // pic_height_in_luma_samples
            if try data.readBit() { // conformance_window_flag
                // The offsets count chroma samples: SubWidthC and SubHeightC of Table 6-1.
                let isSubsampled = !hasSeparateColourPlanes && chromaFormatIdc != 0
                let unitX = isSubsampled && chromaFormatIdc != 3 ? 2 : 1
                let unitY = isSubsampled && chromaFormatIdc == 1 ? 2 : 1
                let left = try data.readUnsignedExpGolombCodedInt()
                let right = try data.readUnsignedExpGolombCodedInt()
                let top = try data.readUnsignedExpGolombCodedInt()
                let bottom = try data.readUnsignedExpGolombCodedInt()
                width -= unitX * (left + right)
                height -= unitY * (top + bottom)
            }
            self.width = width
            self.height = height
            bitDepthLuma = try data.readUnsignedExpGolombCodedInt() + 8
            bitDepthChroma = try data.readUnsignedExpGolombCodedInt() + 8
            let log2MaxPicOrderCountLsb = try data.readUnsignedExpGolombCodedInt() + 4
            let subLayerOrderingInfoPresent = try data.readBit()
            var maxNumReorderPics = 0
            for _ in (subLayerOrderingInfoPresent ? 0 : maxSubLayersMinus1) ... maxSubLayersMinus1 {
                _ = try data.readUnsignedExpGolombCodedInt() // sps_max_dec_pic_buffering_minus1
                maxNumReorderPics = try max(data.readUnsignedExpGolombCodedInt(), maxNumReorderPics)
                _ = try data.readUnsignedExpGolombCodedInt() // sps_max_latency_increase_plus1
            }
            self.maxNumReorderPics = maxNumReorderPics
            // log2_min_luma_coding_block_size_minus3, log2_diff_max_min_luma_coding_block_size,
            // log2_min_luma_transform_block_size_minus2, log2_diff_max_min_luma_transform_block_size,
            // max_transform_hierarchy_depth_inter, max_transform_hierarchy_depth_intra
            for _ in 0 ..< 6 { _ = try data.readUnsignedExpGolombCodedInt() }
            if try data.readBit(), try data.readBit() { // scaling_list_enabled_flag, sps_scaling_list_data_present_flag
                try HevcUtil.skipScalingListData(&data)
            }
            try data.skipBits(2) // amp_enabled_flag, sample_adaptive_offset_enabled_flag
            if try data.readBit() { // pcm_enabled_flag
                try data.skipBits(8) // pcm_sample_bit_depth_luma_minus1, pcm_sample_bit_depth_chroma_minus1
                _ = try data.readUnsignedExpGolombCodedInt() // log2_min_pcm_luma_coding_block_size_minus3
                _ = try data.readUnsignedExpGolombCodedInt() // log2_diff_max_min_pcm_luma_coding_block_size
                try data.skipBit() // pcm_loop_filter_disabled_flag
            }
            try HevcUtil.skipShortTermReferencePictureSets(&data)
            if try data.readBit() { // long_term_ref_pics_present_flag
                for _ in try 0 ..< (data.readUnsignedExpGolombCodedInt()) {
                    try data.skipBits(log2MaxPicOrderCountLsb + 1) // lt_ref_pic_poc_lsb_sps, used_by_curr_pic_lt_sps_flag
                }
            }
            try data.skipBits(2) // sps_temporal_mvp_enabled_flag, strong_intra_smoothing_enabled_flag
            vui = try data.readBit() ? try VideoUsabilityInformation(reading: &data, isH265: true) : nil
        }
    }

    /// Reads profile_tier_level of H.265, 7.3.3, with its general profile.
    private static func readProfileTierLevel<T>(
        _ data: inout ParsableNalUnitBitArray<T>,
        maxSubLayersMinus1: Int
    ) throws -> ProfileTierLevel {
        let profileSpace = try data.readBits(2)
        let isHighTier = try data.readBit()
        let profileIdc = try data.readBits(5)
        var compatibilityFlags: UInt32 = 0
        for profile in 0 ..< 32 where try data.readBit() {
            compatibilityFlags |= 1 << profile
        }
        let constraintBytes = try (0 ..< 6).map { _ in try UInt8(data.readBits(8)) }
        let levelIdc = try data.readBits(8)
        try skipSubLayers(&data, maxSubLayersMinus1: maxSubLayersMinus1)
        return ProfileTierLevel(
            profileSpace: profileSpace,
            isHighTier: isHighTier,
            profileIdc: profileIdc,
            compatibilityFlags: compatibilityFlags,
            constraintBytes: constraintBytes,
            levelIdc: levelIdc
        )
    }

    /// Skips profile_tier_level of H.265, 7.3.3.
    private static func skipProfileTierLevel<T>(
        _ data: inout ParsableNalUnitBitArray<T>,
        profilePresent: Bool,
        maxSubLayersMinus1: Int
    ) throws {
        if profilePresent {
            try data.skipBits(88) // general profile space, tier, profile, compatibility and constraint flags
        }
        try data.skipBits(8) // general_level_idc
        try skipSubLayers(&data, maxSubLayersMinus1: maxSubLayersMinus1)
    }

    /// Skips the profiles and levels of the sub-layers, which end profile_tier_level.
    private static func skipSubLayers<T>(_ data: inout ParsableNalUnitBitArray<T>, maxSubLayersMinus1: Int) throws {
        var subLayerProfilePresent: [Bool] = []
        var subLayerLevelPresent: [Bool] = []
        for _ in 0 ..< maxSubLayersMinus1 {
            try subLayerProfilePresent.append(data.readBit())
            try subLayerLevelPresent.append(data.readBit())
        }
        if maxSubLayersMinus1 > 0 {
            try data.skipBits(2 * (8 - maxSubLayersMinus1)) // reserved_zero_2bits
        }
        for index in 0 ..< maxSubLayersMinus1 {
            if subLayerProfilePresent[index] { try data.skipBits(88) }
            if subLayerLevelPresent[index] { try data.skipBits(8) }
        }
    }

    /// Skips scaling_list_data of H.265, 7.3.4.
    private static func skipScalingListData<T>(_ data: inout ParsableNalUnitBitArray<T>) throws {
        for sizeId in 0 ..< 4 {
            for _ in stride(from: 0, to: 6, by: sizeId == 3 ? 3 : 1) {
                if try !data.readBit() { // scaling_list_pred_mode_flag
                    _ = try data.readUnsignedExpGolombCodedInt() // scaling_list_pred_matrix_id_delta
                } else {
                    let coefficientCount = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 {
                        _ = try data.readSignedExpGolombCodedInt() // scaling_list_dc_coef_minus8
                    }
                    for _ in 0 ..< coefficientCount {
                        _ = try data.readSignedExpGolombCodedInt() // scaling_list_delta_coef
                    }
                }
            }
        }
    }

    /// Skips the st_ref_pic_set structures of a sequence parameter set, H.265 7.3.7.
    private static func skipShortTermReferencePictureSets<T>(_ data: inout ParsableNalUnitBitArray<T>) throws {
        let setCount = try data.readUnsignedExpGolombCodedInt()
        // In a sequence parameter set a set predicted from another takes the one before it.
        var previousDeltaPocCount = 0
        for index in 0 ..< setCount {
            let isPredicted = index != 0 ? try data.readBit() : false
            if isPredicted {
                try data.skipBit() // delta_rps_sign
                _ = try data.readUnsignedExpGolombCodedInt() // abs_delta_rps_minus1
                var deltaPocCount = 0
                for _ in 0 ... previousDeltaPocCount {
                    let usedByCurrentPicture = try data.readBit()
                    let usesDelta = usedByCurrentPicture ? true : try data.readBit()
                    if usesDelta { deltaPocCount += 1 }
                }
                previousDeltaPocCount = deltaPocCount
            } else {
                let negativeCount = try data.readUnsignedExpGolombCodedInt()
                let positiveCount = try data.readUnsignedExpGolombCodedInt()
                for _ in 0 ..< (negativeCount + positiveCount) {
                    _ = try data.readUnsignedExpGolombCodedInt() // delta_poc_minus1
                    try data.skipBit() // used_by_curr_pic_flag
                }
                previousDeltaPocCount = negativeCount + positiveCount
            }
        }
    }

    // MARK: - SEI

    /// The payload of the first SEI message of `payloadType` in the prefix SEI NAL units of an `hvcC` box, then in
    /// its suffix ones, without emulation prevention bytes.
    static func seiPayload(type payloadType: Int, in arrays: [(type: Int, units: [BlockBufferReader])]) -> [UInt8]? {
        for nalType in [prefixSEIType, suffixSEIType] {
            for array in arrays where array.type == nalType {
                for unit in array.units {
                    if let payload = seiPayload(type: payloadType, inNalUnit: unit) { return payload }
                }
            }
        }
        return nil
    }

    private static func seiPayload(type payloadType: Int, inNalUnit unit: BlockBufferReader) -> [UInt8]? {
        let view = BlockBufferView(unit)
        guard view.count > 2 else { return nil }
        let rbsp = removingEmulationPrevention(view.dropFirst(2))
        var offset = 0
        // Each message: payloadType and payloadSize as runs of 0xFF and a last byte, then the payload, until the
        // RBSP trailing bits.
        while offset < rbsp.count, rbsp[offset] != 0x80 {
            var type = 0
            while offset < rbsp.count, rbsp[offset] == 0xFF { type += 255; offset += 1 }
            guard offset < rbsp.count else { return nil }
            type += Int(rbsp[offset]); offset += 1
            var size = 0
            while offset < rbsp.count, rbsp[offset] == 0xFF { size += 255; offset += 1 }
            guard offset < rbsp.count else { return nil }
            size += Int(rbsp[offset]); offset += 1
            guard offset + size <= rbsp.count else { return nil }
            if type == payloadType {
                return Array(rbsp[offset ..< (offset + size)])
            }
            offset += size
        }
        return nil
    }

    private static func removingEmulationPrevention<C: Collection<UInt8>>(_ bytes: C) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            result.append(byte)
        }
        return result
    }

    /// Whether the alpha channel information SEI message, H.265 F.14.2.8, marks premultiplied samples:
    /// alpha_channel_use_idc 1. `nil` when the message cancels the information.
    static func isAlphaPremultiplied(alphaChannelInfo payload: [UInt8]) -> Bool? {
        guard let first = payload.first else { return nil }
        // alpha_channel_cancel_flag (1), alpha_channel_use_idc (3)
        guard first & 0x80 == 0 else { return nil }
        return (first >> 4) & 0x07 == 1
    }

    // MARK: - Alpha layer

    /// Whether the video parameter set describes an auxiliary layer of alpha, as its extension of H.265 F.7.3.2.1.1
    /// tells with an AuxId of 1.
    ///
    /// - Parameter nalUnit: The whole NAL unit, from its two-byte header, with emulation prevention bytes.
    static func hasAlphaLayer(videoParameterSet nalUnit: BlockBufferReader) -> Bool {
        let view = BlockBufferView(nalUnit)
        guard var data = try? ParsableNalUnitBitArray(data: view, offset: view.startIndex + 2, limit: view.endIndex) else {
            return false
        }
        return (try? readHasAlphaLayer(&data)) ?? false
    }

    private static func readHasAlphaLayer<T>(_ data: inout ParsableNalUnitBitArray<T>) throws -> Bool {
        try data.skipBits(4) // vps_video_parameter_set_id
        let baseLayerInternal = try data.readBit()
        try data.skipBit() // vps_base_layer_available_flag
        let maxLayersMinus1 = try data.readBits(6)
        let maxSubLayersMinus1 = try data.readBits(3)
        try data.skipBits(17) // vps_temporal_id_nesting_flag, vps_reserved_0xffff_16bits
        guard maxLayersMinus1 > 0 else { return false }
        try skipProfileTierLevel(&data, profilePresent: true, maxSubLayersMinus1: maxSubLayersMinus1)
        let orderingInfoPresent = try data.readBit()
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1) ... maxSubLayersMinus1 {
            for _ in 0 ..< 3 { _ = try data.readUnsignedExpGolombCodedInt() }
        }
        let maxLayerId = try data.readBits(6)
        let layerSetCountMinus1 = try data.readUnsignedExpGolombCodedInt()
        if layerSetCountMinus1 > 0 {
            try data.skipBits(layerSetCountMinus1 * (maxLayerId + 1)) // layer_id_included_flag
        }
        if try data.readBit() { // vps_timing_info_present_flag
            try data.skipBits(64) // vps_num_units_in_tick, vps_time_scale
            if try data.readBit() { // vps_poc_proportional_to_timing_flag
                _ = try data.readUnsignedExpGolombCodedInt()
            }
            // Hypothetical reference decoder parameters aren't read; a stream with them isn't told apart.
            guard try data.readUnsignedExpGolombCodedInt() == 0 else {
                return false
            }
        }
        guard try data.readBit() else { return false } // vps_extension_flag
        try data.byteAlign()

        // vps_extension()
        if baseLayerInternal {
            try skipProfileTierLevel(&data, profilePresent: false, maxSubLayersMinus1: maxSubLayersMinus1)
        }
        let splitting = try data.readBit()
        var scalabilityTypes: [Int] = []
        for index in 0 ..< 16 where try data.readBit() {
            scalabilityTypes.append(index)
        }
        let auxiliaryScalability = 3
        guard let auxiliaryIndex = scalabilityTypes.firstIndex(of: auxiliaryScalability) else {
            return false
        }
        var dimensionIdLengths: [Int] = []
        for _ in 0 ..< (scalabilityTypes.count - (splitting ? 1 : 0)) {
            try dimensionIdLengths.append(data.readBits(3) + 1)
        }
        let nuhLayerIdPresent = try data.readBit()
        for layer in 1 ... maxLayersMinus1 {
            let layerId = nuhLayerIdPresent ? try data.readBits(6) : layer
            var dimensionIds: [Int] = []
            if splitting {
                // The dimension ids are bit fields of the layer id from its lowest bit, the last one taking the
                // bits left.
                var bitOffset = 0
                for index in scalabilityTypes.indices {
                    let length = index < dimensionIdLengths.count ? dimensionIdLengths[index] : 6 - bitOffset
                    dimensionIds.append((layerId >> bitOffset) & ((1 << max(length, 0)) - 1))
                    bitOffset += length
                }
            } else {
                for length in dimensionIdLengths {
                    try dimensionIds.append(data.readBits(length))
                }
            }
            if auxiliaryIndex < dimensionIds.count, dimensionIds[auxiliaryIndex] == 1 {
                return true
            }
        }
        return false
    }
}

// MARK: - Configuration record

extension HevcUtil {
    /// An `HEVCDecoderConfigurationRecord` of parameter sets as a stream carries them, each kind in an array that
    /// has them all.
    ///
    /// - Parameters:
    ///   - videoParameterSets: Each a whole NAL unit from its header, with emulation prevention bytes.
    ///   - sequenceParameterSet: The first of the sequence parameter sets, read.
    ///   - nalUnitLengthSize: The size of the length before each NAL unit of the samples.
    static func configurationRecord<Unit: Collection<UInt8>>(
        videoParameterSets: [Unit],
        sequenceParameterSets: [Unit],
        pictureParameterSets: [Unit],
        sequenceParameterSet sps: SequenceParameterSet,
        nalUnitLengthSize: Int = 4
    ) -> Data {
        let profileTierLevel = sps.profileTierLevel
        let compatibilityFlags = profileTierLevel.compatibilityFlags.bitReversed
        var record = Data([
            1, // configurationVersion
            UInt8(truncatingIfNeeded: profileTierLevel.profileSpace << 6 | profileTierLevel.profileIdc)
                | (profileTierLevel.isHighTier ? 0x20 : 0),
        ])
        record.append(contentsOf: (0 ..< 4).map { UInt8(truncatingIfNeeded: compatibilityFlags >> (24 - 8 * $0)) })
        record.append(contentsOf: profileTierLevel.constraintBytes)
        record.append(contentsOf: [
            UInt8(truncatingIfNeeded: profileTierLevel.levelIdc),
            0xF0, 0x00, // reserved (4), min_spatial_segmentation_idc (12)
            0xFC, // reserved (6), parallelismType (2)
            0xFC | UInt8(truncatingIfNeeded: sps.chromaFormatIdc),
            0xF8 | UInt8(truncatingIfNeeded: sps.bitDepthLuma - 8),
            0xF8 | UInt8(truncatingIfNeeded: sps.bitDepthChroma - 8),
            0x00, 0x00, // avgFrameRate
            // constantFrameRate (2), numTemporalLayers (3), temporalIdNested (1), lengthSizeMinusOne (2)
            UInt8(truncatingIfNeeded: sps.maxSubLayers << 3 | nalUnitLengthSize - 1) | (sps.isTemporalIDNested ? 0x04 : 0),
        ])
        let arrays = [
            (videoParameterSetType, videoParameterSets),
            (sequenceParameterSetType, sequenceParameterSets),
            (pictureParameterSetType, pictureParameterSets),
        ].filter { !$0.1.isEmpty }
        record.append(UInt8(truncatingIfNeeded: arrays.count))
        for (type, units) in arrays {
            // array_completeness (1), reserved (1), NAL_unit_type (6)
            record.append(0x80 | UInt8(truncatingIfNeeded: type))
            record.append(contentsOf: [UInt8(truncatingIfNeeded: units.count >> 8), UInt8(truncatingIfNeeded: units.count)])
            AvcUtil.appendNalUnits(units, to: &record)
        }
        return record
    }
}

// MARK: - Codec attributes

extension CodecAttributes where Scope == VideoCodec.HEVC {
    /// Reads an `HEVCDecoderConfigurationRecord`, ISO/IEC 14496-15, 8.3.3.1.
    ///
    /// - Parameter record: The payload of an `hvcC` box, its indices starting at 0.
    init(hvcC record: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: record)
        guard try bits.readBits(8) == 1 else {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .hvcC, reason: "Unknown HEVC config version")
        }

        self.init()
        self.profileSpace = try bits.readBits(2)
        self.tier = try bits.readBit() ? .high : .main
        self.profile = try VideoCodec.HEVC.Profile(rawValue: bits.readBits(5))
        self.profileCompatibilityFlags = try bits.readBits(32, as: UInt32.self)
        self.constraintIndicatorFlags = try UInt64(bits.readBitsToLong(48))
        self.level = try VideoCodec.HEVC.Level(rawValue: bits.readBits(8))
        bits.skipBits(4)
        self.minSpatialSegmentation = try bits.readBits(12)
        bits.skipBits(6)
        self.parallelismType = try bits.readBits(2)
        bits.skipBits(6)
        self.chromaFormat = try ChromaFormat(rawValue: bits.readBits(2))
        bits.skipBits(5)
        self.bitDepthLuma = try bits.readBits(3) + 8
        bits.skipBits(5)
        self.bitDepthChroma = try bits.readBits(3) + 8
        self.averageFrameRate = try bits.readBits(16)
        self.constantFrameRate = try bits.readBits(2)
        self.temporalLayerCount = try bits.readBits(3)
        self.isTemporalIDNested = try bits.readBit()
        self.nalUnitLengthSize = try bits.readBits(2) + 1

        var arrays: [VideoCodec.HEVC.NALUnitArray] = []
        for _ in try 0 ..< (bits.readBits(8)) {
            let isComplete = try bits.readBit()
            bits.skipBit()
            let type = try VideoCodec.HEVC.NALUnitType(rawValue: bits.readBits(6))
            let count = try bits.readBits(16)
            let units = try (0 ..< count).map { _ in try bits.readData(length: bits.readBits(16)) }
            arrays.append(VideoCodec.HEVC.NALUnitArray(type: type, isComplete: isComplete, units: units))
        }
        self.nalUnitArrays = arrays
    }

    /// The codec string of RFC 6381, as ISO/IEC 14496-15 Annex E builds it, such as `hvc1.2.4.L153.B0`.
    ///
    /// - Parameter sampleEntryType: `hvc1` or `hev1`, which starts the string.
    func codecs(sampleEntryType: MP4Box.BoxType = .hvc1) -> String? {
        guard let profile = self.profile, let level = self.level else {
            return nil
        }
        let constraints = self.constraintIndicatorFlags ?? 0
        let profileTierLevel = HevcUtil.ProfileTierLevel(
            profileSpace: self.profileSpace ?? 0,
            isHighTier: self.tier == .high,
            profileIdc: profile.rawValue,
            compatibilityFlags: (self.profileCompatibilityFlags ?? 0).bitReversed,
            constraintBytes: (0 ..< 6).map { UInt8(truncatingIfNeeded: constraints >> (40 - 8 * $0)) },
            levelIdc: level.rawValue
        )
        return profileTierLevel.codecs(sampleEntryType: sampleEntryType)
    }
}

private extension UInt32 {
    /// The bits in reverse order: the record writes the compatibility flags with the flag of profile 0 highest.
    var bitReversed: UInt32 {
        (0 ..< 32).reduce(0) { $0 | (self >> (31 - $1) & 1) << $1 }
    }
}
