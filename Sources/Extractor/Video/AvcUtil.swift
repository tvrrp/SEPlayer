//
//  AvcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

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

extension AvcUtil {
    /// An `AVCDecoderConfigurationRecord` of parameter sets as a stream carries them.
    ///
    /// - Parameters:
    ///   - sequenceParameterSets: Each a whole NAL unit from its header, with emulation prevention bytes.
    ///   - sequenceParameterSet: The first of the sequence parameter sets, read.
    ///   - nalUnitLengthSize: The size of the length before each NAL unit of the samples.
    static func configurationRecord<Unit: Collection<UInt8>>(
        sequenceParameterSets: [Unit],
        pictureParameterSets: [Unit],
        sequenceParameterSet sps: NalUnitUtil.SpsData,
        nalUnitLengthSize: Int = 4
    ) -> Data {
        var record = Data([
            1, // configurationVersion
            UInt8(truncatingIfNeeded: sps.profileIdc),
            UInt8(truncatingIfNeeded: sps.constraintsFlagsAndReservedZero2Bits),
            UInt8(truncatingIfNeeded: sps.levelIdc),
            0xFC | UInt8(truncatingIfNeeded: nalUnitLengthSize - 1),
            0xE0 | UInt8(truncatingIfNeeded: sequenceParameterSets.count),
        ])
        appendNalUnits(sequenceParameterSets, to: &record)
        record.append(UInt8(truncatingIfNeeded: pictureParameterSets.count))
        appendNalUnits(pictureParameterSets, to: &record)
        // The high profiles add the chroma and the depths, without extensions of the sequence parameter sets.
        if highProfiles.contains(sps.profileIdc) {
            record.append(contentsOf: [
                0xFC | UInt8(truncatingIfNeeded: sps.chromaFormatIdc),
                0xF8 | UInt8(truncatingIfNeeded: sps.bitDepthLumaMinus8),
                0xF8 | UInt8(truncatingIfNeeded: sps.bitDepthChromaMinus8),
                0,
            ])
        }
        return record
    }

    /// Appends NAL units, each after its 16-bit length, as configuration records hold them.
    static func appendNalUnits<Unit: Collection<UInt8>>(_ units: [Unit], to record: inout Data) {
        for unit in units {
            record.append(contentsOf: [UInt8(truncatingIfNeeded: unit.count >> 8), UInt8(truncatingIfNeeded: unit.count)])
            record.append(contentsOf: unit)
        }
    }

    /// The profiles whose records have the chroma and the depths, ISO/IEC 14496-15 5.3.3.1.2.
    private static var highProfiles: Set<Int> { [100, 110, 122, 144] }
}

extension CodecAttributes where Scope == VideoCodec.H264 {
    /// Reads an `AVCDecoderConfigurationRecord`.
    ///
    /// - Parameter record: The payload of an `avcC` box, its indices starting at 0.
    init(avcC record: BlockBufferReader) throws {
        var reader = record
        guard try reader.readInt(as: UInt8.self) == 1 else {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .avcC, reason: "Unknown AVC config version")
        }

        self.init()
        self.profile = try VideoCodec.H264.Profile(rawValue: Int(reader.readInt(as: UInt8.self)))
        self.constraintFlags = try reader.readInt(as: UInt8.self)
        self.level = try VideoCodec.H264.Level(rawValue: Int(reader.readInt(as: UInt8.self)))
        // reserved (6), lengthSizeMinusOne (2)
        self.nalUnitLengthSize = try Int(reader.readInt(as: UInt8.self) & 0x03) + 1
        // reserved (3), numOfSequenceParameterSets (5)
        let sequenceCount = try Int(reader.readInt(as: UInt8.self) & 0x1F)
        self.sequenceParameterSets = try reader.readNalUnits(count: sequenceCount)
        let pictureCount = try Int(reader.readInt(as: UInt8.self))
        self.pictureParameterSets = try reader.readNalUnits(count: pictureCount)

        // Writers add these for the high profiles: reserved (6), chroma_format (2), reserved (5),
        // bit_depth_luma_minus8 (3), reserved (5), bit_depth_chroma_minus8 (3), then the extensions.
        guard reader.readableBytes >= 4 else { return }
        self.chromaFormat = try ChromaFormat(rawValue: Int(reader.readInt(as: UInt8.self) & 0x03))
        self.bitDepthLuma = try Int(reader.readInt(as: UInt8.self) & 0x07) + 8
        self.bitDepthChroma = try Int(reader.readInt(as: UInt8.self) & 0x07) + 8
        let extensionCount = try Int(reader.readInt(as: UInt8.self))
        self.sequenceParameterSetExtensions = try reader.readNalUnits(count: extensionCount)
    }

    /// The codec string of RFC 6381, such as `avc1.64001F`.
    ///
    /// - Parameter sampleEntryType: `avc1` or `avc3`, which starts the string.
    func codecs(sampleEntryType: MP4Box.BoxType = .avc1) -> String? {
        guard let profile = self.profile, let level = self.level else { return nil }
        return String(
            format: "%@.%02X%02X%02X",
            sampleEntryType.rawValue.fourCharacterCode,
            profile.rawValue,
            self.constraintFlags ?? 0,
            level.rawValue
        )
    }
}

extension BlockBufferReader {
    /// Reads NAL units that each follow a 16-bit length, as configuration records hold them.
    mutating func readNalUnits(count: Int) throws -> [Data] {
        try (0 ..< count).map { _ in
            let length = try Int(readInt(as: UInt16.self))
            return try readData(length: length)
        }
    }
}
