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
        let colorSpace: ColorSpace
//        let colorRange: ColorRange
//        let colorTransfer: ColorTransfer
        let maxNumReorderFrames: Int

        init(data: [UInt8], nalOffset: Int, nalLimit: Int) throws {
            var data = try! ParsableNalUnitBitArray(data: data, offset: nalOffset + 1, limit: nalLimit)
            profileIdc = try! data.readBits(8)
            let constraintsFlagsAndReservedZero2Bits = try! data.readBits(8)
            levelIdc = try! data.readBits(8)
            seqParameterSetId = try! data.readUnsignedExpGolombCodedInt()

            var chromaFormatIdc = 1
            var separateColorPlaneFlag = false
            var bitDepthLumaMinus8 = 0
            var bitDepthChromaMinus8 = 0

            let idcsValues = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138]
            if idcsValues.contains(profileIdc) {
                chromaFormatIdc = try! data.readUnsignedExpGolombCodedInt()
                if chromaFormatIdc == 3 {
                    separateColorPlaneFlag = try! data.readBit()
                }
                bitDepthLumaMinus8 = try! data.readUnsignedExpGolombCodedInt()
                bitDepthChromaMinus8 = try! data.readUnsignedExpGolombCodedInt()
                try! data.skipBit(); // qpprime_y_zero_transform_bypass_flag
                let seqScalingMatrixPresentFlag = try! Bool(data.readBit())
                
                if seqScalingMatrixPresentFlag {
                    let limit = (chromaFormatIdc != 3) ? 8 : 12
                    for index in 0..<limit {
                        let seqScalingListPresentFlag = try! data.readBit()
                        if seqScalingListPresentFlag {
                            try! SpsData.skipScalingList(bitArray: &data, size: index < 6 ? 16 : 64)
                        }
                    }
                }
                
                let frameNumLength = try! data.readUnsignedExpGolombCodedInt() + 4 // log2_max_frame_num_minus4 + 4
                let picOrderCntType = try! data.readUnsignedExpGolombCodedInt()
                var picOrderCntLsbLength = 0
                var deltaPicOrderAlwaysZeroFlag = false
                
                if picOrderCntType == 0 {
                    // log2_max_pic_order_cnt_lsb_minus4 + 4
                    picOrderCntLsbLength = try! data.readUnsignedExpGolombCodedInt() + 4
                } else if picOrderCntType == 1 {
                    deltaPicOrderAlwaysZeroFlag = try! data.readBit() // delta_pic_order_always_zero_flag
                    try! data.readSignedExpGolombCodedInt() // offset_for_non_ref_pic
                    try! data.readSignedExpGolombCodedInt() // offset_for_top_to_bottom_field
                    let numRefFramesInPicOrderCntCycle = try! data.readUnsignedExpGolombCodedInt()
                    
                    for index in 0..<numRefFramesInPicOrderCntCycle {
                        try! data.readUnsignedExpGolombCodedInt() // offset_for_ref_frame[i]
                    }
                }
                
                maxNumRefFrames = try! data.readUnsignedExpGolombCodedInt(); // max_num_ref_frames
                try! data.skipBit() // gaps_in_frame_num_value_allowed_flag
                let picWidthInMbs = try! data.readUnsignedExpGolombCodedInt() + 1
                let picHeightInMapUnits = try! data.readUnsignedExpGolombCodedInt() + 1
                frameMbsOnlyFlag = try! Bool(data.readBit())
                let frameHeightInMbs = (2 - (frameMbsOnlyFlag ? 1 : 0)) * picHeightInMapUnits
                
                if !frameMbsOnlyFlag {
                    try! data.skipBit() // mb_adaptive_frame_field_flag
                }
                
                try! data.skipBit() // direct_8x8_inference_flag
                var frameWidth = picWidthInMbs * 16
                var frameHeight = frameHeightInMbs * 16
                
                let frameCroppingFlag = try! Bool(data.readBit())
                if frameCroppingFlag {
                    let frameCropLeftOffset = try! data.readUnsignedExpGolombCodedInt()
                    let frameCropRightOffset = try! data.readUnsignedExpGolombCodedInt()
                    let frameCropTopOffset = try! data.readUnsignedExpGolombCodedInt()
                    let frameCropBottomOffset = try! data.readUnsignedExpGolombCodedInt()
                    
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
                
                let profileIdcValues = [44, 86, 100, 110, 122, 244]
                // Initialize to the default value defined in section E.2.1 of the H.264 spec. Precisely
                // calculating MaxDpbFrames is complicated, so we short-circuit to the max value of 16 here
                // instead.
                maxNumReorderFrames = profileIdcValues.contains(profileIdc)
                    && (constraintsFlagsAndReservedZero2Bits & 0x10 != 0) ? .zero : 16

                
            }
            fatalError()
        }

        private static func skipScalingList(bitArray: inout ParsableNalUnitBitArray, size: Int) throws {
            var lastScale = 8
            var nextScale = 8

            for index in 0..<size {
                if nextScale != 0 {
                    let deltaScale = try! bitArray.readSignedExpGolombCodedInt()
                    nextScale = (lastScale + deltaScale + 256) % 256
                }

                lastScale = nextScale == 0 ? lastScale : nextScale
            }
        }
    }

    struct PpsData {
        let picParameterSetId: Int
        let seqParameterSetId: Int
        let bottomFieldPicOrderInFramePresentFlag: Bool
    }
}
