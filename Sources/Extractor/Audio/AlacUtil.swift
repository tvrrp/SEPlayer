//
//  AlacUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// Reads the Apple Lossless decoder configuration: the `alac` box inside an `alac` sample entry, a version and flags
/// followed by an `ALACSpecificConfig`.
extension CodecAttributes where Scope == AudioCodec.ALAC {
    /// Reads an `ALACSpecificConfig`.
    ///
    /// - Parameter box: The whole `alac` box, from its size field.
    init(alac box: BlockBufferReader) throws {
        var reader = try box.slice(from: MP4Box.fullHeaderSize)
        self.init()
        self.frameLength = try Int(reader.readInt(as: UInt32.self))
        self.compatibleVersion = try Int(reader.readInt(as: UInt8.self))
        self.bitDepth = try Int(reader.readInt(as: UInt8.self))
        self.historyMultiplier = try Int(reader.readInt(as: UInt8.self))
        self.initialHistory = try Int(reader.readInt(as: UInt8.self))
        self.riceParameterLimit = try Int(reader.readInt(as: UInt8.self))
        self.channelCount = try Int(reader.readInt(as: UInt8.self))
        self.maximumRun = try Int(reader.readInt(as: UInt16.self))
        self.maximumFrameBytes = try Int(reader.readInt(as: UInt32.self))
        self.averageBitrate = try Int(reader.readInt(as: UInt32.self))
        self.sampleRate = try Int(reader.readInt(as: UInt32.self))
    }
}
