//
//  OpusUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import SEPlayerCommon

/// Reads the Opus decoder configuration: the `dOps` box of an `Opus` sample entry.
extension CodecAttributes where Scope == AudioCodec.Opus {
    /// Reads an `OpusSpecificBox`, whose fields are those of the identification header of RFC 7845, 5.1, big-endian:
    /// version (1), OutputChannelCount (1), PreSkip (2), InputSampleRate (4), OutputGain (2), ChannelMappingFamily
    /// (1), then with a family other than 0 StreamCount (1), CoupledCount (1) and a ChannelMapping entry for each
    /// output channel.
    ///
    /// - Parameter box: The payload of a `dOps` box, its indices starting at 0.
    init(dOps box: BlockBufferReader) throws {
        var reader = box
        guard try reader.readInt(as: UInt8.self) == 0 else {
            throw BoxParser.BoxParserErrors.badBoxContent(type: .dOps, reason: "Unknown Opus config version")
        }
        let channelCount = try Int(reader.readInt(as: UInt8.self))

        self.init()
        self.channelCount = channelCount
        self.preSkip = try Int(reader.readInt(as: UInt16.self))
        self.inputSampleRate = try Int(reader.readInt(as: UInt32.self))
        self.outputGain = try Int(reader.readInt(as: Int16.self))
        let family = try Int(reader.readInt(as: UInt8.self))
        self.channelMappingFamily = family
        if family != 0 {
            self.streamCount = try Int(reader.readInt(as: UInt8.self))
            self.coupledStreamCount = try Int(reader.readInt(as: UInt8.self))
            self.channelMapping = try reader.readBytes(length: channelCount)
        }
    }
}
