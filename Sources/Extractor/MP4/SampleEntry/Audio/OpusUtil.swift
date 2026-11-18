//
//  OpusUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import SEPlayerCommon

/// Reads the Opus decoder configuration of an MP4 file: the `dOps` box of an `Opus` sample entry.
enum OpusUtil {
    /// The magic cookie of a `dOps` box: the `OpusHead` header of RFC 7845, 5.1, which carries the same fields in
    /// little-endian byte order.
    ///
    /// - Parameter box: The whole box, from its size field: version (1), OutputChannelCount (1), PreSkip (2),
    ///   InputSampleRate (4), OutputGain (2), ChannelMappingFamily (1), then with a family other than 0 StreamCount
    ///   (1), CoupledCount (1) and a ChannelMapping entry for each output channel.
    static func magicCookie(dOps box: BlockBufferReader) -> BlockBufferReader? {
        do {
            var reader = try box.slice(from: MP4Box.headerSize)
            guard try reader.readInt(as: UInt8.self) == 0 else { return nil }
            let channelCount = try reader.readInt(as: UInt8.self)
            let preSkip = try reader.readInt(as: UInt16.self)
            let inputSampleRate = try reader.readInt(as: UInt32.self)
            let outputGain = try reader.readInt(as: UInt16.self)
            let mappingFamily = try reader.readInt(as: UInt8.self)
            let mapping = mappingFamily == 0 ? [] : try reader.readBytes(length: 2 + Int(channelCount))

            let head = Array("OpusHead".utf8) + [1, channelCount]
                + preSkip.littleEndianBytes + inputSampleRate.littleEndianBytes + outputGain.littleEndianBytes
                + [mappingFamily] + mapping
            return try BlockBufferReader(bytes: head)
        } catch {
            return nil
        }
    }

    /// The stream description of an Opus stream with `magicCookie`, completed by the decoder from the fields of the
    /// sample entry.
    static func streamDescription(
        magicCookie: BlockBufferReader,
        sampleEntryDescription: AudioStreamBasicDescription
    ) -> AudioStreamBasicDescription? {
        var description = sampleEntryDescription
        description.mFormatID = kAudioFormatOpus
        return try? AudioFormatProperties.formatInfo(description: description, magicCookie: magicCookie)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
