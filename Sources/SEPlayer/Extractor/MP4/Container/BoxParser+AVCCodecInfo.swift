//
//  BoxParser+AVCCodecInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia.CMFormatDescription

extension BoxParser {
    struct AvcConfig: Format.InitializationData {
        let nalUnitLengthFieldLength: Int
        let width: Int
        let height: Int
        let bitdepthLuma: Int
        let bitdepthChroma: Int
        let maxNumReorderFrames: Int
        let pixelWidthHeightRatio: Float
        let codecs: String?

        private let codecInfo: CMVideoFormatDescription

        init(data: inout ByteBuffer) throws {
            do {
                // Skip avvC config version, profile compatibility, level indication
                data.moveReaderIndex(forwardBy: 4)
                // lengthSizeMinusOne + 1
                // bit(6) reserved, int(2) lengthSizeMinusOne, bit(3) reserved
                nalUnitLengthFieldLength = try Int(data.readInt(as: Int8.self) & 0x3 + 1)
                guard nalUnitLengthFieldLength != 3 else {
                    throw ErrorBuilder.illegalState
                }

                func readNalUnit(reader: inout ByteBuffer) throws -> ByteBuffer {
                    let length = try reader.readInt(as: Int16.self)
                    return try reader.readThrowingSlice(length: Int(length))
                }

                let numbOfSpss = try data.readInt(as: Int8.self) & 0x1F
                let sequenceParameterSets = try (0..<numbOfSpss).map { _ in try readNalUnit(reader: &data) }

                let numOfPpss = try data.readInt(as: Int8.self)
                let pictureParameterSets = try (0..<numOfPpss).map { _ in try readNalUnit(reader: &data) }

                codecInfo = try CMVideoFormatDescription(
                    h264ParameterSets: (sequenceParameterSets + pictureParameterSets).map { Data(buffer: $0) },
                    nalUnitHeaderLength: nalUnitLengthFieldLength
                )

                var width = Format.noValue
                var height = Format.noValue
                var bitdepthLuma = Format.noValue
                var bitdepthChroma = Format.noValue
                // Max possible value defined in section E.2.1 of the H.264 spec.
                var maxNumReorderFrames = 16
                var pixelWidthHeightRatio: Float = 1
                var codecs: String?

                if numbOfSpss > 0 {
                    let sps = sequenceParameterSets[0].readableBytesView
                    let spsData = try NalUnitUtil.SpsData(data: sps, nalOffset: 0, nalLimit: sps.count)

                    width = spsData.width
                    height = spsData.height
                    bitdepthLuma = spsData.bitDepthLumaMinus8 + 8
                    bitdepthChroma = spsData.bitDepthChromaMinus8 + 8
                    maxNumReorderFrames = spsData.maxNumReorderFrames
                    pixelWidthHeightRatio = spsData.pixelWidthHeightRatio
                    codecs = String(
                        format: "avc1.%02X%02X%02X",
                        spsData.profileIdc,
                        spsData.constraintsFlagsAndReservedZero2Bits,
                        spsData.levelIdc
                    )
                }

                self.width = width
                self.height = height
                self.bitdepthLuma = bitdepthLuma
                self.bitdepthChroma = bitdepthChroma
                self.maxNumReorderFrames = maxNumReorderFrames
                self.pixelWidthHeightRatio = pixelWidthHeightRatio
                self.codecs = codecs
            } catch {
                throw BoxParserErrors.badBoxContent(type: .avcC, reason: "Error parsing AVC config")
            }
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            return codecInfo
        }
    }
}
