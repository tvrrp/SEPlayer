//
//  H263Util.swift
//  SEPlayer
//

import SEPlayerCommon

extension CodecAttributes where Scope == VideoCodec.H263 {
    /// Reads an `H263SpecificBox` of 3GPP TS 26.244: vendor (32), decoder_version (8), H263_Level (8),
    /// H263_Profile (8).
    ///
    /// - Parameter box: The payload of a `d263` box, its indices starting at 0.
    init(d263 box: BlockBufferReader) throws {
        var reader = box
        self.init()
        self.vendor = try FourCharacterCode(reader.readInt(as: UInt32.self))
        self.decoderVersion = try Int(reader.readInt(as: UInt8.self))
        self.level = try Int(reader.readInt(as: UInt8.self))
        self.profile = try Int(reader.readInt(as: UInt8.self))
    }
}
