//
//  AmrUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import SEPlayerCommon

/// Reads the AMR decoder configuration of 3GPP TS 26.244: the `damr` box of a `samr` or `sawb` sample entry, or the
/// `samr` box in a QuickTime `wave` box, with the same fields.
enum AmrUtil {
    /// The magic cookie of an AMR decoder configuration: a `frma` box naming the format, a big-endian `enda` box,
    /// the configuration in a box named by the format, and a box of size zero, as QuickTime's `wave` box has them.
    ///
    /// - Parameter config: The configuration, the payload of its box.
    static func magicCookie(format: MP4Box.BoxType, config: BlockBufferReader) -> BlockBufferReader? {
        guard let configBytes = try? config.getBytes(at: config.readerIndex, length: config.readableBytes) else {
            return nil
        }
        let cookie = BlockBufferReader.box(type: .frma, payload: format.rawValue.bigEndianBytes)
            + BlockBufferReader.box(type: .enda, payload: UInt16(0).bigEndianBytes)
            + BlockBufferReader.box(type: .samr, payload: configBytes)
            + BlockBufferReader.terminatorBox
        return try? BlockBufferReader(bytes: cookie)
    }

    /// The stream description of AMR in `format`, `samr` narrowband or `sawb` wideband, with `magicCookie`.
    static func streamDescription(format: MP4Box.BoxType, magicCookie: BlockBufferReader) -> AudioStreamBasicDescription? {
        let description = AudioStreamBasicDescription(
            mSampleRate: format == .samr ? 8000 : 16000,
            mFormatID: format.rawValue,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return try? AudioFormatProperties.formatInfo(description: description, magicCookie: magicCookie)
    }
}
