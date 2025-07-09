//
//  NalUnitUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.06.2025.
//

enum NalUnitUtil {
    struct SpsData {
        let profileIdc: Int
        let constraintsFlagsAndReservedZero2Bits: Int
        let levelIdc: Int
        let seqParameterSetId: Int
        let maxNumRefFrames: Int
        let width: Int
        let height: Int
        let pixelWidthHeightRatio: Float
        let bitDepthLumaMinus8: Int
        let bitDepthChromaMinus8: Int
        let separateColorPlaneFlag: Bool
        let frameMbsOnlyFlag: Bool
        let frameNumLength: Int
        let picOrderCountType: Int
        let picOrderCntLsbLength: Int
        let deltaPicOrderAlwaysZeroFlag: Bool
        let colorSpace: ColorSpace?
        let colorRange: ColorRange?
        let colorTransfer: ColorTransfer?
        let maxNumReorderFrames: Int

        init(data: ByteBufferView, nalOffset: Int, nalLimit: Int) throws {
            var data = try ParsableNalUnitBitArray(data: data, offset: nalOffset + 1, limit: nalLimit)
            profileIdc = try data.readBits(8)
            let constraintsFlagsAndReservedZero2Bits = try data.readBits(8)
            levelIdc = try data.readBits(8)
            seqParameterSetId = try data.readUnsignedExpGolombCodedInt()

            var chromaFormatIdc = 1
            var separateColorPlaneFlag = false
            var bitDepthLumaMinus8 = 0
            var bitDepthChromaMinus8 = 0

            let idcsValues = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138]
            if idcsValues.contains(profileIdc) {
                chromaFormatIdc = try data.readUnsignedExpGolombCodedInt()
                if chromaFormatIdc == 3 {
                    separateColorPlaneFlag = try data.readBit()
                }
                bitDepthLumaMinus8 = try data.readUnsignedExpGolombCodedInt()
                bitDepthChromaMinus8 = try data.readUnsignedExpGolombCodedInt()
                try data.skipBit(); // qpprime_y_zero_transform_bypass_flag
                let seqScalingMatrixPresentFlag = try Bool(data.readBit())

                if seqScalingMatrixPresentFlag {
                    let limit = (chromaFormatIdc != 3) ? 8 : 12
                    for index in 0..<limit {
                        let seqScalingListPresentFlag = try data.readBit()
                        if seqScalingListPresentFlag {
                            try SpsData.skipScalingList(bitArray: &data, size: index < 6 ? 16 : 64)
                        }
                    }
                }
            }

            let frameNumLength = try data.readUnsignedExpGolombCodedInt() + 4 // log2_max_frame_num_minus4 + 4
            let picOrderCntType = try data.readUnsignedExpGolombCodedInt()
            var picOrderCntLsbLength = 0
            var deltaPicOrderAlwaysZeroFlag = false

            if picOrderCntType == 0 {
                // log2_max_pic_order_cnt_lsb_minus4 + 4
                picOrderCntLsbLength = try data.readUnsignedExpGolombCodedInt() + 4
            } else if picOrderCntType == 1 {
                deltaPicOrderAlwaysZeroFlag = try data.readBit() // delta_pic_order_always_zero_flag
                try data.readSignedExpGolombCodedInt() // offset_for_non_ref_pic
                try data.readSignedExpGolombCodedInt() // offset_for_top_to_bottom_field
                let numRefFramesInPicOrderCntCycle = try data.readUnsignedExpGolombCodedInt()

                for index in 0..<numRefFramesInPicOrderCntCycle {
                    try data.readUnsignedExpGolombCodedInt() // offset_for_ref_frame[i]
                }
            }

            maxNumRefFrames = try data.readUnsignedExpGolombCodedInt(); // max_num_ref_frames
            try data.skipBit() // gaps_in_frame_num_value_allowed_flag
            let picWidthInMbs = try data.readUnsignedExpGolombCodedInt() + 1
            let picHeightInMapUnits = try data.readUnsignedExpGolombCodedInt() + 1
            frameMbsOnlyFlag = try Bool(data.readBit())
            let frameHeightInMbs = (2 - (frameMbsOnlyFlag ? 1 : 0)) * picHeightInMapUnits

            if !frameMbsOnlyFlag {
                try data.skipBit() // mb_adaptive_frame_field_flag
            }

            try data.skipBit() // direct_8x8_inference_flag
            var frameWidth = picWidthInMbs * 16
            var frameHeight = frameHeightInMbs * 16

            let frameCroppingFlag = try data.readBit()
            if frameCroppingFlag {
                let frameCropLeftOffset = try data.readUnsignedExpGolombCodedInt()
                let frameCropRightOffset = try data.readUnsignedExpGolombCodedInt()
                let frameCropTopOffset = try data.readUnsignedExpGolombCodedInt()
                let frameCropBottomOffset = try data.readUnsignedExpGolombCodedInt()

                let cropUnitX: Int
                let cropUnitY: Int

                if chromaFormatIdc == 0 {
                    cropUnitX = 1
                    cropUnitY = 2 - (frameMbsOnlyFlag ? 1 : 0)
                } else {
                    let subWidthC = chromaFormatIdc == 3 ? 1 : 2
                    let subHeightC = chromaFormatIdc == 1 ? 2 : 1
                    cropUnitX = subWidthC
                    cropUnitY = subHeightC * (2 - (frameMbsOnlyFlag ? 1 : 0))
                }

                frameWidth -= (frameCropLeftOffset + frameCropRightOffset) * cropUnitX
                frameHeight -= (frameCropTopOffset + frameCropBottomOffset) * cropUnitY
            }

            var colorSpace: ColorSpace?
            var colorRange: ColorRange?
            var colorTransfer: ColorTransfer?
            var pixelWidthHeightRatio: Float = 1

            let profileIdcValues = [44, 86, 100, 110, 122, 244]
            // Initialize to the default value defined in section E.2.1 of the H.264 spec. Precisely
            // calculating MaxDpbFrames is complicated, so we short-circuit to the max value of 16 here
            // instead.
            var maxNumReorderFrames = profileIdcValues.contains(profileIdc)
                && (constraintsFlagsAndReservedZero2Bits & 0x10 != 0) ? .zero : 16

            if try data.readBit() { // vui_parameters_present_flag
                // Section E.1.1: VUI parameters syntax
                let aspectRatioInfoPresentFlag = try data.readBit()
                if aspectRatioInfoPresentFlag {
                    let aspectRatioIdc = try data.readBits(8)
                    if aspectRatioIdc == .extendedSar {
                        let sarWidth = try data.readBits(16)
                        let sarHeight = try data.readBits(16)
                        if sarWidth != sarHeight {
                            pixelWidthHeightRatio = Float(sarWidth) / Float(sarHeight)
                        }
                    } else if aspectRatioIdc < NalUnitUtil.aspectRatioIdcValues.count {
                        pixelWidthHeightRatio = NalUnitUtil.aspectRatioIdcValues[aspectRatioIdc]
                    } else {
                        print("Unexpected aspect_ratio_idc value: \(aspectRatioIdc)")
                    }
                }

                if try data.readBit() { // overscan_info_present_flag
                    try data.skipBit() // overscan_appropriate_flag
                }

                if try data.readBit() { // video_signal_type_present_flag
                    try data.skipBits(3) // video_format
                    colorRange = try data.readBit() ? .full : .limited

                    if try data.readBit() { // colour_description_present_flag
                        let colorPrimaries = try data.readBits(8) // colour_primaries
                        let transferCharacteristics = try data.readBits(8) // transfer_characteristics
                        try data.skipBits(8) // matrix_coeffs

                        colorSpace = ColorSpace(isoColorPrimaries: colorPrimaries)
                        colorTransfer = ColorTransfer(isoTransferCharacteristics: transferCharacteristics)
                    }
                }

                if try data.readBit() { // chroma_loc_info_present_flag
                    try data.readUnsignedExpGolombCodedInt() // chroma_sample_loc_type_top_field
                    try data.readUnsignedExpGolombCodedInt() // chroma_sample_loc_type_bottom_field
                }
                if try data.readBit() { // timing_info_present_flag
                    try data.skipBits(65) // num_units_in_tick (32), time_scale (32), fixed_frame_rate_flag (1)
                }

                let nalHrdParametersPresent = try data.readBit() // nal_hrd_parameters_present_flag
                if nalHrdParametersPresent {
                    try SpsData.skipHrdParameters(data: &data)
                }
                let vclHrdParametersPresent = try data.readBit() // vcl_hrd_parameters_present_flag
                if vclHrdParametersPresent {
                    try SpsData.skipHrdParameters(data: &data)
                }
                if nalHrdParametersPresent || vclHrdParametersPresent {
                    try data.skipBit() // low_delay_hrd_flag
                }

                try data.skipBit() // pic_struct_present_flag
                if try data.readBit() { // bitstream_restriction_flag
                    try data.skipBit() // motion_vectors_over_pic_boundaries_flag
                    try data.readUnsignedExpGolombCodedInt() // max_bytes_per_pic_denom
                    try data.readUnsignedExpGolombCodedInt() // max_bits_per_mb_denom
                    try data.readUnsignedExpGolombCodedInt() // log2_max_mv_length_horizontal
                    try data.readUnsignedExpGolombCodedInt() // log2_max_mv_length_vertical
                    maxNumReorderFrames = try data.readUnsignedExpGolombCodedInt() // max_num_reorder_frames
                    try data.readUnsignedExpGolombCodedInt() // max_dec_frame_buffering
                }
            }

            self.constraintsFlagsAndReservedZero2Bits = constraintsFlagsAndReservedZero2Bits
            self.width = frameWidth
            self.height = frameHeight
            self.pixelWidthHeightRatio = pixelWidthHeightRatio
            self.bitDepthLumaMinus8 = bitDepthLumaMinus8
            self.bitDepthChromaMinus8 = bitDepthChromaMinus8
            self.separateColorPlaneFlag = separateColorPlaneFlag
            self.frameNumLength = frameNumLength
            self.picOrderCountType = picOrderCntType
            self.picOrderCntLsbLength = picOrderCntLsbLength
            self.deltaPicOrderAlwaysZeroFlag = deltaPicOrderAlwaysZeroFlag
            self.colorSpace = colorSpace
            self.colorRange = colorRange
            self.colorTransfer = colorTransfer
            self.maxNumReorderFrames = maxNumReorderFrames
        }

        private static func skipScalingList(bitArray: inout ParsableNalUnitBitArray, size: Int) throws {
            var lastScale = 8
            var nextScale = 8

            for index in 0..<size {
                if nextScale != 0 {
                    let deltaScale = try bitArray.readSignedExpGolombCodedInt()
                    nextScale = (lastScale + deltaScale + 256) % 256
                }

                lastScale = nextScale == 0 ? lastScale : nextScale
            }
        }

        private static func skipHrdParameters(data: inout ParsableNalUnitBitArray) throws {
            let codedPictureBufferCount = try data.readUnsignedExpGolombCodedInt() + 1 // cpb_cnt_minus1
            try data.skipBits(8) // bit_rate_scale (4), cpb_size_scale (4)
            for _ in 0..<codedPictureBufferCount {
                try data.readUnsignedExpGolombCodedInt() // bit_rate_value_minus1[i]
                try data.readUnsignedExpGolombCodedInt() // cpb_size_value_minus1[i]
                try data.skipBit() // cbr_flag[i]
            }
            // initial_cpb_removal_delay_length_minus1 (5)
            // cpb_removal_delay_length_minus1 (5)
            // dpb_output_delay_length_minus1 (5)
            // time_offset_length (5)
            try data.skipBits(20)
        }
    }

    struct PpsData {
        let picParameterSetId: Int
        let seqParameterSetId: Int
        let bottomFieldPicOrderInFramePresentFlag: Bool
    }
}

private extension NalUnitUtil {
    static let aspectRatioIdcValues: [Float] = [
        1, // Unspecified. Assume square
        1,
        12 / 11,
        10 / 11,
        16 / 11,
        40 / 33,
        24 / 11,
        20 / 11,
        32 / 11,
        80 / 33,
        18 / 11,
        15 / 11,
        64 / 33,
        160 / 99,
        4 / 3,
        3 / 2,
        2
    ]
}

private extension Int {
    static let extendedSar: Int = 0xFF
}
