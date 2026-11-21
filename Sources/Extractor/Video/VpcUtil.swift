//
//  VpcUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the VP codec configuration record of the VP9 ISOBMFF binding, the `vpcC` box of `vp08` and `vp09` entries.
extension CodecAttributes where Scope == VideoCodec.VP {
    /// Reads a `VPCodecConfigurationRecord` with its version and flags: version (8), flags (24), profile (8),
    /// level (8), bitDepth (4), chromaSubsampling (3), videoFullRangeFlag (1), colourPrimaries (8),
    /// transferCharacteristics (8), matrixCoefficients (8), then the size of codec initialization data and the data.
    ///
    /// - Parameter record: The payload of a `vpcC` box, its indices starting at 0.
    init(vpcC record: BlockBufferReader) throws {
        var bits = BlockBufferBitReader(reader: record)
        guard try bits.readBits(8) == 1 else {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .vpcC, reason: "Unknown VP config version")
        }
        bits.skipBits(24)

        self.init()
        self.profile = try bits.readBits(8)
        self.level = try bits.readBits(8)
        self.bitDepth = try bits.readBits(4)
        self.chromaSubsampling = try VideoCodec.VP.ChromaSubsampling(rawValue: bits.readBits(3))
        self.isFullRange = try bits.readBit()
        self.colorPrimaries = try ColorPrimaries(rawValue: bits.readBits(8))
        self.transferFunction = try TransferFunction(rawValue: bits.readBits(8))
        self.matrixCoefficients = try MatrixCoefficients(rawValue: bits.readBits(8))
        let initializationDataSize = try bits.readBits(16)
        if initializationDataSize > 0 {
            self.codecInitializationData = try bits.readData(length: initializationDataSize)
        }
    }

    /// The codec string of the VP9 codec string specification, such as `vp09.02.10.10`.
    ///
    /// - Parameter sampleEntryType: `vp08` or `vp09`, which starts the string.
    func codecs(sampleEntryType: MP4Box.BoxType) -> String? {
        guard let profile = self.profile, let level = self.level else { return nil }
        let type = sampleEntryType.rawValue.fourCharacterCode
        return String(format: "%@.%02d.%02d.%02d", type, profile, level, self.bitDepth ?? 8)
    }
}
