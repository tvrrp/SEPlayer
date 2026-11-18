//
//  DolbyVisionUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the Dolby Vision decoder configuration records of the Dolby Vision ISOBMFF specification.
enum DolbyVisionUtil {
    /// A `dvcC`, `dvvC` or `dvwC` box: the Dolby Vision decoder configuration record.
    struct Configuration {
        let profile: Int
        let level: Int
        let blSignalCompatibilityId: Int

        init(reader: inout BlockBufferReader) throws {
            try reader.skip(2) // dv_version_major, dv_version_minor
            let bits = try reader.readInt(as: UInt16.self)
            profile = Int(bits >> 9)
            level = Int((bits >> 3) & 0x3F)
            // rpu_present_flag (1), el_present_flag (1), bl_present_flag (1)
            blSignalCompatibilityId = Int(try reader.readInt(as: UInt8.self) >> 4)
        }

        /// Profile 5 carries IPTPQc2 only Dolby Vision can show; the others have a base layer HEVC decoders show.
        var isBaseLayerCompatible: Bool { profile != 5 && blSignalCompatibilityId != 0 }

        /// The codec string, such as `dvh1.05.06`.
        func codecs(sampleEntryType: MP4Box.BoxType) -> String {
            String(format: "%@.%02d.%02d", sampleEntryType.rawValue.fourCharacterCode, profile, level)
        }
    }
}
