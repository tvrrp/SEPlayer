//
//  AvcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Reads the AVC decoder configuration of ISO/IEC 14496-15, 5.3.3, the `avcC` box.
enum AvcUtil {
    /// The first sequence parameter set of an `avcC` box, whole from its header.
    ///
    /// - Parameter avcC: The payload of the box, its indices starting at 0.
    static func firstSequenceParameterSet(avcC: BlockBufferReader) -> BlockBufferReader? {
        guard let count = try? avcC.getInt(at: 5, as: UInt8.self), count & 0x1F > 0,
              let length = try? Int(avcC.getInt(at: 6, as: UInt16.self)), length > 1 else {
            return nil
        }
        return try? avcC.getSlice(at: 8, length: length)
    }

    /// Whether an `avcC` box has a sequence and a picture parameter set.
    ///
    /// - Parameter avcC: The payload of the box, its indices starting at 0.
    static func hasParameterSets(avcC: BlockBufferReader) -> Bool {
        guard let sequenceCount = try? Int(avcC.getInt(at: 5, as: UInt8.self) & 0x1F), sequenceCount > 0 else {
            return false
        }
        var offset = 6
        for _ in 0 ..< sequenceCount {
            guard let length = try? Int(avcC.getInt(at: offset, as: UInt16.self)) else {
                return false
            }
            offset += 2 + length
        }
        guard let pictureCount = try? avcC.getInt(at: offset, as: UInt8.self) else {
            return false
        }
        return pictureCount > 0
    }
}

struct AvcConfig: Format.InitializationData {
    let nalUnitLengthFieldLength: Int
    let width: Int
    let height: Int
    let bitdepthLuma: Int
    let bitdepthChroma: Int
    let maxNumReorderFrames: Int
    let pixelWidthHeightRatio: Float
    let codecs: String?

    /// `nil` without a sequence and a picture parameter set: an `avc3` sample entry may leave them to the samples.
    private let codecInfo: CMVideoFormatDescription?

    /// Whether the configuration has the parameter sets the decoder needs.
    var hasParameterSets: Bool { codecInfo != nil }

    init(data: inout BlockBufferReader) throws {
        do {
            // Skip avvC config version, profile compatibility, level indication
            try data.skip(4)
            // lengthSizeMinusOne + 1
            // bit(6) reserved, int(2) lengthSizeMinusOne, bit(3) reserved
            let nalUnitLengthFieldLength = try Int(data.readInt(as: Int8.self) & 0x3 + 1)
            guard nalUnitLengthFieldLength != 3 else {
                throw ErrorBuilder.illegalState()
            }

            func readNalUnit(reader: inout BlockBufferReader) throws -> BlockBufferView {
                let length = try reader.readInt(as: UInt16.self)
                return try BlockBufferView(reader.readSlice(length: Int(length)))
            }

            let numbOfSpss = try data.readInt(as: Int8.self) & 0x1F
            let sequenceParameterSets = try (0 ..< numbOfSpss).map { _ in try readNalUnit(reader: &data) }

            let numOfPpss = try data.readInt(as: Int8.self)
            let pictureParameterSets = try (0 ..< numOfPpss).map { _ in try readNalUnit(reader: &data) }

            try self.init(
                sequenceParameterSets: sequenceParameterSets,
                pictureParameterSets: pictureParameterSets,
                nalUnitLengthFieldLength: nalUnitLengthFieldLength
            )
        } catch {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .avcC, reason: "Error parsing AVC config")
        }
    }

    /// A configuration from parameter sets, each a whole NAL unit from its header, with emulation prevention bytes.
    init<Bytes: RandomAccessCollection<UInt8>>(
        sequenceParameterSets: [Bytes],
        pictureParameterSets: [Bytes],
        nalUnitLengthFieldLength: Int
    ) throws where Bytes.Index == Int {
        self.nalUnitLengthFieldLength = nalUnitLengthFieldLength
        codecInfo = sequenceParameterSets.isEmpty || pictureParameterSets.isEmpty ? nil : try CMVideoFormatDescription(
            h264ParameterSets: (sequenceParameterSets + pictureParameterSets).map { Data($0) },
            nalUnitHeaderLength: nalUnitLengthFieldLength
        )

        guard let sps = sequenceParameterSets.first else {
            width = Format.noValue
            height = Format.noValue
            bitdepthLuma = Format.noValue
            bitdepthChroma = Format.noValue
            // Max possible value defined in section E.2.1 of the H.264 spec.
            maxNumReorderFrames = 16
            pixelWidthHeightRatio = 1
            codecs = nil
            return
        }

        let spsData = try NalUnitUtil.parseSpsNalUnit(nalData: sps, nalOffset: sps.startIndex, nalLimit: sps.endIndex)
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

    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        guard let codecInfo else {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .avcC, reason: "No parameter sets in the AVC config")
        }
        return codecInfo
    }
}
