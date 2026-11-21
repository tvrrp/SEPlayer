//
//  FlacUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the FLAC decoder configuration: the `dfLa` box of a `fLaC` sample entry, with the stream's metadata blocks.
extension CodecAttributes where Scope == AudioCodec.FLAC {
    /// Reads the metadata blocks of a `dfLa` box: STREAMINFO, then the blocks after it.
    ///
    /// - Parameter box: The whole box, from its size field: the header (8), version and flags (4), then the blocks.
    init(dfLa box: BlockBufferReader) throws {
        var bits = try BlockBufferBitReader(reader: box.slice(from: MP4Box.fullHeaderSize))
        self.init()
        var additional: [AudioCodec.FLAC.MetadataBlock] = []
        var isFirst = true
        var isLast = false
        while !isLast {
            isLast = try bits.readBit()
            let type = try bits.readBits(7)
            let length = try bits.readBits(24)
            guard isFirst else {
                try additional.append(AudioCodec.FLAC.MetadataBlock(type: type, data: bits.readData(length: length)))
                continue
            }
            guard type == 0, length == 34 else {
                throw BoxParser.BoxParserErrors.badBoxContent(type: .dfLa, reason: "No STREAMINFO")
            }
            isFirst = false
            self.minimumBlockSize = try bits.readBits(16)
            self.maximumBlockSize = try bits.readBits(16)
            self.minimumFrameSize = try bits.readBits(24)
            self.maximumFrameSize = try bits.readBits(24)
            self.sampleRate = try bits.readBits(20)
            self.channelCount = try bits.readBits(3) + 1
            self.bitsPerSample = try bits.readBits(5) + 1
            self.totalSamples = try Int(bits.readBitsToLong(36))
            self.signature = try bits.readData(length: 16)
        }
        self.additionalMetadataBlocks = additional
    }
}
