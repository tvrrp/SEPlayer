//
//  NalUnitUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.06.2025.
//

import CoreMedia
import SEPlayerCommon

public enum NalUnitUtil {
    /// The H.265 access unit delimiter.
    private static let h265NalUnitTypeAud = 35

    public static func parseSpsNalUnit<T: RandomAccessCollection<UInt8>>(
        nalData: T,
        nalOffset: Int,
        nalLimit: Int
    ) throws -> SpsData where T.Index == Int {
        try SpsData(data: nalData, nalOffset: nalOffset + 1, nalLimit: nalLimit)
    }

    public static func parsePpsNalUnit<T: RandomAccessCollection<UInt8>>(
        nalData: T,
        nalOffset: Int,
        nalLimit: Int
    ) throws -> PpsData where T.Index == Int {
        try PpsData(data: nalData, nalOffset: nalOffset + 1, nalLimit: nalLimit)
    }

    public static func clearPrefixFlags(_ prefixFlags: inout (Bool, Bool, Bool)) {
        prefixFlags = (false, false, false)
    }

    /// - Parameter allocator: The allocator of the unescaped copy; `nil` for the default one.
    public static func unescapeStream(
        _ source: CMBlockBuffer,
        length: Int,
        allocator: CFAllocator? = nil
    ) throws -> CMBlockBuffer {
        let scratch = try source.makeContiguous(allocator: allocator, flags: .alwaysCopyData)

        let unescapedLength = try scratch.withUnsafeMutableBlockBytes { destination -> Int in
            let bytes = destination.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var write = 0
            var read = 0
            while read < length {
                if read + 2 < length,
                   bytes[read] == 0x00,
                   bytes[read + 1] == 0x00,
                   bytes[read + 2] == 0x03 {
                    bytes[write] = 0x00
                    bytes[write + 1] = 0x00
                    write += 2
                    read += 3
                } else {
                    bytes[write] = bytes[read]
                    write += 1
                    read += 1
                }
            }
            return write
        }

        return try CMBlockBuffer(bufferReference: scratch, range: 0 ..< unescapedLength)
    }

    // TODO: just pass slice of RandomAccessCollection<UInt8> and ignore offset and limit
    public static func findNalUnit<T: RandomAccessCollection<UInt8>>(
        _ data: T,
        offset: Int,
        limit: Int,
        prefixFlags: inout (Bool, Bool, Bool)
    ) -> Int where T.Index == Int {
        let length = limit - offset
        if prefixFlags.0 {
            clearPrefixFlags(&prefixFlags)
            return offset - 3
        } else if length > 1, prefixFlags.1, data[offset] == 1 {
            clearPrefixFlags(&prefixFlags)
            return offset - 2
        } else if length > 2, prefixFlags.2, data[offset] == 0, data[offset + 1] == 1 {
            clearPrefixFlags(&prefixFlags)
            return offset - 1
        }

        // We're looking for the NAL unit start code prefix 0x000001. The value of i tracks the
        // index of the third byte.
        var i = offset + 2
        while i < limit - 1 {
            if data[i] & 0xFE != 0 {
                // There isn't a NAL prefix here, or at the next two positions.
                i += 3
            } else if data[i - 2] == 0, data[i - 1] == 0, data[i] == 1 {
                clearPrefixFlags(&prefixFlags)
                return i - 2
            } else {
                // There isn't a NAL prefix here, but there might be at the next position.
                i += 1
            }
        }

        // True if the last three bytes in the data seen so far are {0,0,1}.
        if length > 2 {
            prefixFlags.0 = data[limit - 3] == 0 && data[limit - 2] == 0 && data[limit - 1] == 1
        } else if length == 2 {
            prefixFlags.0 = prefixFlags.2 && data[limit - 2] == 0 && data[limit - 1] == 1
        } else {
            prefixFlags.0 = prefixFlags.1 && data[limit - 1] == 1
        }
        // True if the last two bytes in the data seen so far are {0,0}.
        if length > 1 {
            prefixFlags.1 = data[limit - 2] == 0 && data[limit - 1] == 0
        } else {
            prefixFlags.1 = prefixFlags.2 && data[limit - 1] == 0
        }
        // True if the last byte in the data seen so far is {0}.
        prefixFlags.2 = data[limit - 1] == 0

        return limit
    }

    public struct SpsData {
        public let profileIdc: Int
        public let constraintsFlagsAndReservedZero2Bits: Int
        public let levelIdc: Int
        public let seqParameterSetId: Int
        public let maxNumRefFrames: Int
        public let width: Int
        public let height: Int
        public let pixelWidthHeightRatio: Float
        public let bitDepthLumaMinus8: Int
        public let bitDepthChromaMinus8: Int
        public let separateColorPlaneFlag: Bool
        public let frameMbsOnlyFlag: Bool
        public let frameNumLength: Int
        public let picOrderCountType: Int
        public let picOrderCntLsbLength: Int
        public let deltaPicOrderAlwaysZeroFlag: Bool
        public let colorSpace: ColorSpace?
        public let colorRange: ColorRange?
        public let colorTransfer: ColorTransfer?
        public let maxNumReorderFrames: Int
        public let chromaFormatIdc: Int
        /// The video usability information, if the parameter set has one.
        let vui: VideoUsabilityInformation?

        public init<T: RandomAccessCollection<UInt8>>(
            data: T,
            nalOffset: Int,
            nalLimit: Int
        ) throws where T.Index == Int {
            var data = try ParsableNalUnitBitArray(data: data, offset: nalOffset, limit: nalLimit)
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
                try data.skipBit() // qpprime_y_zero_transform_bypass_flag
                let seqScalingMatrixPresentFlag = try Bool(data.readBit())

                if seqScalingMatrixPresentFlag {
                    let limit = (chromaFormatIdc != 3) ? 8 : 12
                    for index in 0 ..< limit {
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

                for _ in 0 ..< numRefFramesInPicOrderCntCycle {
                    try data.readUnsignedExpGolombCodedInt() // offset_for_ref_frame[i]
                }
            }

            maxNumRefFrames = try data.readUnsignedExpGolombCodedInt() // max_num_ref_frames
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

            var vui: VideoUsabilityInformation?
            if try data.readBit() { // vui_parameters_present_flag
                // Section E.1.1: VUI parameters syntax
                let parameters = try VideoUsabilityInformation(reading: &data, isH265: false)
                vui = parameters
                if let aspectRatio = parameters.aspectRatio {
                    if aspectRatio.indicator == .extendedSar {
                        if aspectRatio.sarWidth != aspectRatio.sarHeight, aspectRatio.sarHeight != 0 {
                            pixelWidthHeightRatio = Float(aspectRatio.sarWidth) / Float(aspectRatio.sarHeight)
                        }
                    } else if aspectRatio.indicator < NalUnitUtil.aspectRatioIdcValues.count {
                        pixelWidthHeightRatio = NalUnitUtil.aspectRatioIdcValues[aspectRatio.indicator]
                    } else {
                        SELogger.warning(.mp4, "Unexpected aspect_ratio_idc value \(aspectRatio.indicator)")
                    }
                }
                if let fullRange = parameters.videoFullRange {
                    colorRange = fullRange ? .full : .limited
                }
                if let colour = parameters.colourDescription {
                    colorSpace = ColorSpace(isoColorPrimaries: colour.colourPrimaries)
                    colorTransfer = ColorTransfer(isoTransferCharacteristics: colour.transferCharacteristics)
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
            self.chromaFormatIdc = chromaFormatIdc
            self.vui = vui
        }

        private static func skipScalingList<T>(bitArray: inout ParsableNalUnitBitArray<T>, size: Int) throws {
            var lastScale = 8
            var nextScale = 8

            for _ in 0 ..< size {
                if nextScale != 0 {
                    let deltaScale = try bitArray.readSignedExpGolombCodedInt()
                    nextScale = (lastScale + deltaScale + 256) % 256
                }

                lastScale = nextScale == 0 ? lastScale : nextScale
            }
        }

        private static func skipHrdParameters<T>(data: inout ParsableNalUnitBitArray<T>) throws {
            let codedPictureBufferCount = try data.readUnsignedExpGolombCodedInt() + 1 // cpb_cnt_minus1
            try data.skipBits(8) // bit_rate_scale (4), cpb_size_scale (4)
            for _ in 0 ..< codedPictureBufferCount {
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

    public struct PpsData {
        public let picParameterSetId: Int
        public let seqParameterSetId: Int
        public let bottomFieldPicOrderInFramePresentFlag: Bool

        public init(picParameterSetId: Int, seqParameterSetId: Int, bottomFieldPicOrderInFramePresentFlag: Bool) {
            self.picParameterSetId = picParameterSetId
            self.seqParameterSetId = seqParameterSetId
            self.bottomFieldPicOrderInFramePresentFlag = bottomFieldPicOrderInFramePresentFlag
        }

        public init<T: RandomAccessCollection<UInt8>>(
            data: T,
            nalOffset: Int,
            nalLimit: Int
        ) throws where T.Index == Int {
            var data = try ParsableNalUnitBitArray(data: data, offset: nalOffset, limit: nalLimit)
            picParameterSetId = try data.readUnsignedExpGolombCodedInt()
            seqParameterSetId = try data.readUnsignedExpGolombCodedInt()
            try data.skipBit() // entropy_coding_mode_flag
            bottomFieldPicOrderInFramePresentFlag = try data.readBit()
        }
    }

    public static func isH264NalUnitDependedOn(nalUnitHeaderFirstByte: UInt8) -> Bool {
        let nalRefIdc = Int((nalUnitHeaderFirstByte & 0x60) >> 5)
        if nalRefIdc != 0 {
            // A picture with nal_ref_idc not equal to 0 is a reference picture, which contains
            // samples that may be used for inter prediction in the decoding process of subsequent
            // pictures in decoding order.
            return true
        }

        switch H264NalUnitType(rawValue: Int(nalUnitHeaderFirstByte & 0x1F)) {
        case .nonIdr:
            // For pictures (Video Coding Layer NAL units), we can rely on nal_ref_idc to determine
            // whether future NAL units depend on it.
            return false
        case .aud:
            // NAL unit delimiters are not depended on.
            return false
        case .prefix:
            // Prefix NAL units are only used by Annex G scalable video coding to mark temporal layers.
            // Rely on nal_ref_idc to identify sample dependencies.
            return false
        default:
            // Treat any other NAL unit type as depended on. This might be too restrictive, but reduces
            // risks around closed captions, HDR metadata in SEI messages.
            return true
        }
    }

    public static func numberOfBytesInNalUnitHeader(format: Format) -> Int {
        let mimeType = getNalStructureMimeType(format: format)
        if mimeType == .videoH264 {
            return 1
        }
        if mimeType == .videoH265 {
            return 2
        }
        return 0
    }

    public static func isDependedOn<T: RandomAccessCollection<UInt8>>(
        data: T,
        format: Format
    ) -> Bool where T.Index == Int {
        switch getNalStructureMimeType(format: format) {
        case .videoH264:
            guard let first = data.first else { return true }
            return isH264NalUnitDependedOn(nalUnitHeaderFirstByte: first)
        case .videoH265:
            guard data.count >= 2 else { return true }
            let start = data.startIndex
            return isH265NalUnitDependedOn(
                nalUnitHeaderFirstByte: data[start],
                secondByte: data[start + 1],
                format: format
            )
        default:
            return true
        }
    }

    /// Whether a later frame may depend on the H.265 NAL unit with this header.
    ///
    /// A sub-layer non-reference picture of the highest temporal sub-layer isn't depended on, and neither is an access
    /// unit delimiter. Everything else is treated as depended on.
    public static func isH265NalUnitDependedOn(nalUnitHeaderFirstByte: UInt8, secondByte: UInt8, format: Format) -> Bool {
        let nalUnitType = Int((nalUnitHeaderFirstByte >> 1) & 0x3F)
        if nalUnitType == h265NalUnitTypeAud {
            return false
        }

        // TRAIL_N, TSA_N, STSA_N, RADL_N, RASL_N and the reserved RSV_VCL_N10/12/14: even types up to 14.
        let isSubLayerNonReferencePicture = nalUnitType <= 14 && nalUnitType % 2 == 0
        let temporalId = Int(secondByte & 0x07) - 1
        if isSubLayerNonReferencePicture, format.maxSubLayers > 0, temporalId == format.maxSubLayers - 1 {
            return false
        }
        return true
    }

    /// Whether a later frame may depend on the sample: whether any of its NAL units is depended on.
    ///
    /// - Parameters:
    ///   - sample: The sample, as NAL units each prefixed with its length.
    ///   - nalUnitLengthFieldLength: The size of the length prefix, in bytes: 1, 2 or 4.
    public static func isSampleDependedOn(
        _ sample: BlockBufferReader,
        nalUnitLengthFieldLength: Int,
        format: Format
    ) throws -> Bool {
        let headerLength = numberOfBytesInNalUnitHeader(format: format)
        guard headerLength > 0, [1, 2, 4].contains(nalUnitLengthFieldLength) else {
            return true
        }

        var reader = sample
        while reader.readableBytes >= nalUnitLengthFieldLength {
            let nalUnitLength = switch nalUnitLengthFieldLength {
            case 1: try Int(reader.readInt(as: UInt8.self))
            case 2: try Int(reader.readInt(as: UInt16.self))
            default: try Int(reader.readInt(as: UInt32.self))
            }
            guard nalUnitLength >= headerLength, nalUnitLength <= reader.readableBytes else {
                // A malformed sample may be anything: it stays depended on.
                return true
            }

            let header = try reader.readBytes(length: headerLength)
            if isDependedOn(data: header, format: format) {
                return true
            }
            reader.moveReaderIndex(forwardBy: nalUnitLength - headerLength)
        }
        return false
    }

    private static func getNalStructureMimeType(format: Format) -> MimeTypes? {
        if let codecs = format.codecs, format.sampleMimeType == .videoDolbyVision {
            if codecs.hasPrefix("dva1") || codecs.hasPrefix("dvav") {
                return .videoH264
            } else if codecs.hasPrefix("dvh1") || codecs.hasPrefix("dvhe") {
                return .videoH265
            }
        }

        return format.sampleMimeType
    }
}

public extension NalUnitUtil {
    enum H264NalUnitType: Int {
        case unspecified = 0
        case nonIdr = 1
        case partitionA = 2
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case aud = 9
        case prefix = 14
    }

    static let nalStartCode: [UInt8] = [0, 0, 0, 1]
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
        2,
    ]
}

private extension Int {
    static let extendedSar: Int = 0xFF
}
