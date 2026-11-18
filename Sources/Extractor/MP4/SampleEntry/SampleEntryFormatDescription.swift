//
//  SampleEntryFormatDescription.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// The format description of a sample entry, read from the entry itself.
struct SampleEntryFormatDescription: Format.InitializationData, @unchecked Sendable {
    let formatDescription: CMFormatDescription

    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        formatDescription
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.formatDescription.equalTo(rhs.formatDescription)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(formatDescription.mediaType.rawValue)
        hasher.combine(formatDescription.mediaSubType.rawValue)
    }
}
