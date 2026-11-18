//
//  ColorInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import SEPlayerCommon

/// An `nclx` `colr` box: the color description of ISO/IEC 23091-2.
struct ColorInfo {
    let primaries: Int
    let transfer: Int
    let matrix: Int
    let isFullRange: Bool

    /// `nil` for color boxes other than `nclx`, as ICC profiles.
    init?(reader: inout BlockBufferReader) throws {
        let colorType = try MP4Box.BoxType(rawValue: reader.readInt(as: UInt32.self))
        guard colorType == .nclx || colorType == .nclc else { return nil }
        primaries = try Int(reader.readInt(as: UInt16.self))
        transfer = try Int(reader.readInt(as: UInt16.self))
        matrix = try Int(reader.readInt(as: UInt16.self))
        isFullRange = try colorType == .nclx ? (reader.readInt(as: UInt8.self) & 0x80) != 0 : false
    }

    var videoRange: Format.VideoRange {
        switch transfer {
        case 16: .pq
        case 18: .hlg
        default: .sdr
        }
    }
}
