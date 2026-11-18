//
//  Av1Util.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// Reads the AV1 codec configuration record of the AV1 ISOBMFF binding, the `av1C` box, and the sequence header
/// OBU of its configOBUs.
struct Av1Configuration {
    let profile: Int
    /// seq_level_idx_0 and seq_tier_0.
    let level: Int
    let isHighTier: Bool
    let bitDepth: Int
    let isMonochrome: Bool
    let chromaSubsamplingX: Bool
    let chromaSubsamplingY: Bool
    /// chroma_sample_position: 0 unknown, 1 vertical, 2 colocated.
    let chromaSamplePosition: Int
    /// The color config of the sequence header, when the configOBUs have one.
    let colorConfig: ColorConfig?
    /// Whether the configOBUs carry metadata OBUs, such as HDR metadata.
    let hasMetadata: Bool

    struct ColorConfig {
        /// The color description, or `nil` without color_description_present_flag.
        let colorPrimaries: Int
        let transferCharacteristics: Int
        let matrixCoefficients: Int
        let isFullRange: Bool
    }

    private static let sequenceHeaderType = 1
    private static let metadataType = 5

    /// - Parameter av1C: The payload of the box, its indices starting at 0: marker (1), version (7), seq_profile (3),
    ///   seq_level_idx_0 (5), seq_tier_0 (1), high_bitdepth (1), twelve_bit (1), monochrome (1),
    ///   chroma_subsampling_x (1), chroma_subsampling_y (1), chroma_sample_position (2), then 8 bits of presentation
    ///   delay, then configOBUs.
    init?(av1C: BlockBufferReader) {
        guard av1C.readableBytes >= 4,
              let marker = try? av1C.getInt(at: av1C.readerIndex, as: UInt8.self), marker == 0x81,
              let second = try? av1C.getInt(at: av1C.readerIndex + 1, as: UInt8.self),
              let third = try? av1C.getInt(at: av1C.readerIndex + 2, as: UInt8.self),
              var configOBUs = try? av1C.slice(from: av1C.readerIndex + 4) else {
            return nil
        }
        profile = Int(second >> 5)
        level = Int(second & 0x1F)
        isHighTier = third & 0x80 != 0
        let highBitDepth = third & 0x40 != 0
        let twelveBit = third & 0x20 != 0
        bitDepth = highBitDepth ? (twelveBit ? 12 : 10) : 8
        isMonochrome = third & 0x10 != 0
        chromaSubsamplingX = third & 0x08 != 0
        chromaSubsamplingY = third & 0x04 != 0
        chromaSamplePosition = Int(third & 0x03)

        var colorConfig: ColorConfig?
        var hasMetadata = false
        while configOBUs.readableBytes > 0, let obu = try? Self.readOBU(&configOBUs) {
            if obu.type == Self.sequenceHeaderType, colorConfig == nil {
                colorConfig = try? Self.readColorConfig(sequenceHeader: obu.payload)
            } else if obu.type == Self.metadataType {
                hasMetadata = true
            }
        }
        self.colorConfig = colorConfig
        self.hasMetadata = hasMetadata
    }

    /// The chroma location of both fields, as an index of the chroma locations of H.264 Table E-1: the position the
    /// header names, or the one usual for the subsampling.
    var chromaLocationIndex: Int {
        switch chromaSamplePosition {
        case 2:
            return 3
        case 0:
            if chromaSubsamplingX && !chromaSubsamplingY && !isMonochrome { return 3 }
            if !chromaSubsamplingX && !chromaSubsamplingY && !isMonochrome { return 1 }
            return 0
        default:
            return 0
        }
    }

    // MARK: - OBUs

    /// Reads an OBU: its type and its payload. OBUs of configOBUs carry their size; one without takes the rest.
    private static func readOBU(_ reader: inout BlockBufferReader) throws -> (type: Int, payload: BlockBufferReader) {
        let header = try reader.readInt(as: UInt8.self)
        let type = Int((header >> 3) & 0x0F)
        if header & 0x04 != 0 { try reader.skip(1) } // obu_extension_header
        guard header & 0x02 != 0 else {
            return try (type, reader.readSlice(length: reader.readableBytes))
        }
        // leb128() of AV1 4.10.5.
        var size = 0
        for index in 0 ..< 8 {
            let byte = try reader.readInt(as: UInt8.self)
            size |= Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { break }
        }
        return try (type, reader.readSlice(length: size))
    }

    /// The color_config of a sequence_header_obu, AV1 5.5.
    private static func readColorConfig(sequenceHeader: BlockBufferReader) throws -> ColorConfig {
        var bits = BlockBufferBitReader(reader: sequenceHeader)
        let profile = try bits.readBits(3)
        try bits.skipBits(throwing: 1) // still_picture
        let reducedStillPictureHeader = try bits.readBits(1) == 1
        var hasOrderHint = false
        if reducedStillPictureHeader {
            try bits.skipBits(throwing: 5) // seq_level_idx[0]
        } else {
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if try bits.readBits(1) == 1 { // timing_info_present_flag
                try bits.skipBits(throwing: 64) // num_units_in_display_tick, time_scale
                if try bits.readBits(1) == 1 { // equal_picture_interval
                    try bits.skipUVLC() // num_ticks_per_picture_minus_1
                }
                decoderModelInfoPresent = try bits.readBits(1) == 1
                if decoderModelInfoPresent {
                    bufferDelayLength = try bits.readBits(5) + 1
                    try bits.skipBits(throwing: 32 + 5 + 5) // num_units_in_decoding_tick, two time lengths
                }
            }
            let initialDisplayDelayPresent = try bits.readBits(1) == 1
            let operatingPointCount = try bits.readBits(5) + 1
            for _ in 0 ..< operatingPointCount {
                try bits.skipBits(throwing: 12) // operating_point_idc
                if try bits.readBits(5) > 7 { // seq_level_idx
                    try bits.skipBits(throwing: 1) // seq_tier
                }
                if decoderModelInfoPresent, try bits.readBits(1) == 1 { // decoder_model_present_for_this_op
                    try bits.skipBits(throwing: 2 * bufferDelayLength + 1) // buffer delays, low_delay_mode_flag
                }
                if initialDisplayDelayPresent, try bits.readBits(1) == 1 {
                    try bits.skipBits(throwing: 4) // initial_display_delay_minus_1
                }
            }
        }
        let widthBits = try bits.readBits(4) + 1
        let heightBits = try bits.readBits(4) + 1
        try bits.skipBits(throwing: widthBits + heightBits) // max_frame_width_minus_1, max_frame_height_minus_1
        if !reducedStillPictureHeader, try bits.readBits(1) == 1 { // frame_id_numbers_present_flag
            try bits.skipBits(throwing: 4 + 3) // delta_frame_id_length_minus_2, additional_frame_id_length_minus_1
        }
        try bits.skipBits(throwing: 3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
        if !reducedStillPictureHeader {
            try bits.skipBits(throwing: 4) // interintra compound, masked compound, warped motion, dual filter
            hasOrderHint = try bits.readBits(1) == 1
            if hasOrderHint {
                try bits.skipBits(throwing: 2) // enable_jnt_comp, enable_ref_frame_mvs
            }
            var forceScreenContentTools = 2
            if try bits.readBits(1) == 0 { // seq_choose_screen_content_tools
                forceScreenContentTools = try bits.readBits(1)
            }
            if forceScreenContentTools > 0, try bits.readBits(1) == 0 { // seq_choose_integer_mv
                try bits.skipBits(throwing: 1) // seq_force_integer_mv
            }
            if hasOrderHint {
                try bits.skipBits(throwing: 3) // order_hint_bits_minus_1
            }
        }
        try bits.skipBits(throwing: 3) // enable_superres, enable_cdef, enable_restoration

        // color_config()
        let highBitDepth = try bits.readBits(1) == 1
        if profile == 2, highBitDepth {
            try bits.skipBits(throwing: 1) // twelve_bit
        }
        let isMonochrome = profile == 1 ? false : try bits.readBits(1) == 1
        var primaries = 2, transfer = 2, matrix = 2
        if try bits.readBits(1) == 1 { // color_description_present_flag
            primaries = try bits.readBits(8)
            transfer = try bits.readBits(8)
            matrix = try bits.readBits(8)
        }
        let isFullRange: Bool = if isMonochrome {
            try bits.readBits(1) == 1
        } else if primaries == 1, transfer == 13, matrix == 0 {
            // sRGB is full range.
            true
        } else {
            try bits.readBits(1) == 1
        }
        return ColorConfig(colorPrimaries: primaries, transferCharacteristics: transfer, matrixCoefficients: matrix, isFullRange: isFullRange)
    }
}

extension Av1Configuration {
    /// The codec string of the AV1 ISOBMFF binding, such as `av01.0.04M.10`.
    var codecs: String {
        String(format: "av01.%d.%02d%@.%02d", profile, level, isHighTier ? "H" : "M", bitDepth)
    }

    /// The range of brightness by the transfer characteristics of the sequence header.
    var videoRange: Format.VideoRange? {
        switch colorConfig?.transferCharacteristics {
        case 16?: .pq
        case 18?: .hlg
        case nil: nil
        default: .sdr
        }
    }
}

private extension BlockBufferBitReader {
    /// Skips `count` bits, throwing when fewer are left.
    mutating func skipBits(throwing count: Int) throws {
        guard bitsLeft >= count else { throw EndOfFileError() }
        skipBits(count)
    }

    /// Skips a uvlc() of AV1 4.10.3.
    mutating func skipUVLC() throws {
        var leadingZeros = 0
        while try !readBit() {
            leadingZeros += 1
            guard leadingZeros < 32 else { return }
        }
        try skipBits(throwing: leadingZeros)
    }
}
