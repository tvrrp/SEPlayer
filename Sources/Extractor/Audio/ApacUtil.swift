//
//  ApacUtil.swift
//  SEPlayer
//

import Foundation
import SEPlayerCommon

extension CodecAttributes where Scope == AudioCodec.APAC {
    /// Reads the start of an APAC configuration: version and flags (32), the version of the bitstream (16), then
    /// the global config, whose first fields are the profile (6) and the level (4).
    ///
    /// - Parameter box: The whole `dapa` box, from its size field, which decoders take as their configuration.
    init(dapa box: BlockBufferReader) throws {
        var bits = try BlockBufferBitReader(reader: box.slice(from: MP4Box.fullHeaderSize))
        let bitstreamVersion = try bits.readBits(16)

        self.init()
        self.bitstreamVersion = bitstreamVersion
        self.decoderSpecificInfo = try box.getData(at: box.readerIndex, length: box.readableBytes)
        // The global config of other versions of the bitstream may start otherwise.
        guard bitstreamVersion == Self.globalConfigVersion else { return }
        self.profile = try bits.readBits(6)
        self.level = try bits.readBits(4)
    }

    /// The codec string of RFC 6381: the profile and the level in decimal, such as `apac.05.00`.
    var codecs: String? {
        guard let profile = self.profile, let level = self.level else { return nil }
        return String(format: "apac.%02d.%02d", profile, level)
    }

    /// The version of the bitstream whose global config starts with the profile and the level.
    private static var globalConfigVersion: Int { 0x0800 }
}
