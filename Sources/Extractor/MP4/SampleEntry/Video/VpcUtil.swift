//
//  VpcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the VP codec configuration record of the VP9 ISOBMFF binding, the `vpcC` box of `vp08` and `vp09` entries.
///
/// The decoder reads what it needs from the frames: the format description keeps the box as it is. The record tells
/// the track's codec string and its range of brightness.
struct VpcConfiguration {
    let profile: Int
    let level: Int
    let bitDepth: Int
    let chromaSubsampling: Int
    let isFullRange: Bool
    let colourPrimaries: Int
    let transferCharacteristics: Int
    let matrixCoefficients: Int

    /// - Parameter vpcC: The payload of the box, its indices starting at 0: version (8), flags (24), profile (8),
    ///   level (8), bitDepth (4), chromaSubsampling (3), videoFullRangeFlag (1), colourPrimaries (8),
    ///   transferCharacteristics (8), matrixCoefficients (8), then the size of codec initialization data and the data.
    init?(vpcC: BlockBufferReader) {
        guard vpcC.readableBytes >= 12,
              let fields = try? vpcC.getBytes(at: vpcC.readerIndex, length: 10), fields[0] == 1 else {
            return nil
        }
        profile = Int(fields[4])
        level = Int(fields[5])
        bitDepth = Int(fields[6] >> 4)
        chromaSubsampling = Int((fields[6] >> 1) & 0x07)
        isFullRange = fields[6] & 0x01 != 0
        colourPrimaries = Int(fields[7])
        transferCharacteristics = Int(fields[8])
        matrixCoefficients = Int(fields[9])
    }

    /// The codec string of the VP9 codec string specification, such as `vp09.02.10.10`.
    func codecs(sampleEntryType: MP4Box.BoxType) -> String {
        String(format: "%@.%02d.%02d.%02d", sampleEntryType.rawValue.fourCharacterCode, profile, level, bitDepth)
    }

    /// The range of brightness by the transfer characteristics of ISO/IEC 23091-2.
    var videoRange: Format.VideoRange {
        switch transferCharacteristics {
        case 16: .pq
        case 18: .hlg
        default: .sdr
        }
    }
}
