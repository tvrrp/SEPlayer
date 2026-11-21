//
//  BoxParser+CoreMediaParsers.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.10.2025.
//

import CoreMedia
import SEPlayerCommon

extension BoxParser {
    /// The system's description of a whole video sample entry, for entries not read here.
    ///
    /// - Parameter entry: The entry, from its size field, its indices starting at 0.
    static func systemVideoDescription(entry: BlockBufferReader, isQuickTime: Bool) throws -> CMFormatDescription {
        try entry.withUnsafeReadableBlockBuffer { blockBuffer in
            try CMFormatDescription(
                bigEndianImageDescription: blockBuffer,
                flavor: isQuickTime ? .quickTimeMovie : .isoFamily
            )
        }
    }
}
