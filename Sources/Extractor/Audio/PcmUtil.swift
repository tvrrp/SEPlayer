//
//  PcmUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import SEPlayerCommon

/// Describes linear PCM sample entries: QuickTime's formats, named by their sample type and byte order, and ISO's
/// `ipcm` and `fpcm`, described by a `pcmC` box.
enum PcmUtil {
    /// The QuickTime formats of linear PCM whose fields of version 0 and 1 describe the samples, with the format
    /// `0` of the oldest files.
    static let quickTimeFormats: Set<UInt32> = Set([
        MP4Box.BoxType.NONE, .raw_, .twos, .sowt, .lpcm, .in24, .in32, .fl32, .fl64,
    ].map(\.rawValue) + [0])

    /// The samples of a QuickTime linear PCM entry of version 0 or 1.
    ///
    /// The format tells the sample type, and for 24 and 32 bit integers and floats their size; `raw ` of 8 bits is
    /// unsigned. Samples are big-endian except `sowt`, and the sizes given by the format unless an `enda` box marks
    /// them little-endian.
    static func attributes(
        format rawFormat: UInt32,
        sampleSize: Int,
        isLittleEndian: Bool
    ) -> CodecAttributes<AudioCodec.PCM> {
        let format = MP4Box.BoxType(rawValue: rawFormat)
        var attributes = CodecAttributes<AudioCodec.PCM>()
        attributes.sampleFormat = switch format {
        case .fl32?,
             .fl64?: .float
        case nil,
             .raw_?,
             .NONE?: sampleSize == 8 ? .unsignedInteger : .signedInteger
        default: .signedInteger
        }
        attributes.isBigEndian = switch format {
        case .fl32?,
             .fl64?,
             .in24?,
             .in32?: !isLittleEndian
        case .sowt?: false
        default: true
        }
        attributes.bitDepth = switch format {
        case .fl32?,
             .in32?: 32
        case .fl64?: 64
        case .in24?: 24
        default: sampleSize
        }
        return attributes
    }

    /// The samples of a QuickTime version 2 entry of linear PCM, by its format flags: float (bit 0), big-endian
    /// (bit 1) and signed integer (bit 2).
    static func attributes(version2 fields: SoundDescription.Version2Fields) -> CodecAttributes<AudioCodec.PCM> {
        var attributes = CodecAttributes<AudioCodec.PCM>()
        attributes.bitDepth = Int(fields.bitsPerChannel)
        attributes.isBigEndian = fields.formatFlags & 0x02 != 0
        attributes.sampleFormat = if fields.formatFlags & 0x01 != 0 {
            .float
        } else if fields.formatFlags & 0x04 != 0 {
            .signedInteger
        } else {
            .unsignedInteger
        }
        return attributes
    }

    /// The samples of an `ipcm` or `fpcm` entry with its `pcmC` box of ISO/IEC 23003-5: integers or floats, of a
    /// size and a byte order the box tells.
    ///
    /// - Parameter box: The payload of the box: version and flags (4), format_flags (1), whose first bit marks
    ///   little-endian samples, and PCM_sample_size (1).
    static func attributes(pcmC box: BlockBufferReader, isFloat: Bool) -> CodecAttributes<AudioCodec.PCM>? {
        guard let formatFlags = try? box.getInt(at: 4, as: UInt8.self),
              let sampleSize = try? box.getInt(at: 5, as: UInt8.self),
              sampleSize > 0, sampleSize % 8 == 0 else {
            return nil
        }
        var attributes = CodecAttributes<AudioCodec.PCM>()
        attributes.bitDepth = Int(sampleSize)
        attributes.isBigEndian = formatFlags & 0x01 == 0
        attributes.sampleFormat = isFloat ? .float : .signedInteger
        return attributes
    }
}
