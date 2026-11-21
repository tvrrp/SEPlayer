//
//  DolbyVisionUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the Dolby Vision decoder configuration records of the Dolby Vision ISOBMFF specification.
extension CodecAttributes where Scope == VideoCodec.DolbyVision {
    /// Reads a `DOVIDecoderConfigurationRecord`.
    ///
    /// - Parameter record: The payload of a `dvcC`, `dvvC` or `dvwC` box, its indices starting at 0.
    init(dvcC record: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: record)
        self.init()
        self.versionMajor = try bits.readBits(8)
        self.versionMinor = try bits.readBits(8)
        self.profile = try bits.readBits(7)
        self.level = try bits.readBits(6)
        self.hasReferenceProcessingUnit = try bits.readBit()
        self.hasEnhancementLayer = try bits.readBit()
        self.hasBaseLayer = try bits.readBit()
        self.baseLayerSignalCompatibilityID = try bits.readBits(4)
    }

    /// The codec string, such as `dvh1.05.06`.
    ///
    /// - Parameter sampleEntryType: The sample entry of the stream, such as `dvh1` or `dvhe`.
    func codecs(sampleEntryType: MP4Box.BoxType) -> String? {
        guard let profile = self.profile, let level = self.level else { return nil }
        return String(format: "%@.%02d.%02d", sampleEntryType.rawValue.fourCharacterCode, profile, level)
    }
}
