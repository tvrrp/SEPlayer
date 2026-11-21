//
//  AmrUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import SEPlayerCommon

/// Reads the AMR decoder configuration of 3GPP TS 26.244: the `damr` box of a `samr` or `sawb` sample entry, or the
/// `samr` box in a QuickTime `wave` box, with the same fields.
extension CodecAttributes where Scope == AudioCodec.AMR {
    /// Reads an `AMRSpecificBox` of 3GPP TS 26.244: vendor (32), decoder_version (8), mode_set (16),
    /// mode_change_period (8), frames_per_sample (8).
    ///
    /// - Parameter box: The payload of a `damr` box, its indices starting at 0.
    init(damr box: BlockBufferReader) throws {
        var reader = box
        self.init()
        self.vendor = try FourCharacterCode(reader.readInt(as: UInt32.self))
        self.decoderVersion = try Int(reader.readInt(as: UInt8.self))
        self.modeSet = try Int(reader.readInt(as: UInt16.self))
        self.modeChangePeriod = try Int(reader.readInt(as: UInt8.self))
        self.framesPerSample = try Int(reader.readInt(as: UInt8.self))
    }
}
