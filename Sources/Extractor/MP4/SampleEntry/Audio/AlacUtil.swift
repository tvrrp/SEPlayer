//
//  AlacUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import SEPlayerCommon

/// Reads the Apple Lossless decoder configuration: the `alac` box inside an `alac` sample entry, a version and flags
/// followed by an `ALACSpecificConfig`.
enum AlacUtil {
    /// The box from its size field: header (8), version and flags (4), frameLength (4), compatibleVersion (1),
    /// bitDepth (1), pb (1), mb (1), kb (1), numChannels (1), maxRun (2), maxFrameBytes (4), avgBitRate (4),
    /// sampleRate (4).
    private static let boxSize = 36

    /// The stream description of an `alac` box.
    static func streamDescription(alac box: BlockBufferReader) -> AudioStreamBasicDescription? {
        guard box.readableBytes >= boxSize,
              let sampleRate = try? box.getInt(at: 32, as: Int32.self),
              let frameLength = try? box.getInt(at: 12, as: UInt32.self),
              let bitDepth = try? box.getInt(at: 17, as: UInt8.self),
              let channelCount = try? box.getInt(at: 21, as: UInt8.self) else {
            return nil
        }
        return AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: sourceBitDepthFlags(bitDepth: Int(bitDepth)),
            mBytesPerPacket: 0,
            mFramesPerPacket: frameLength,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// The magic cookie of an `alac` box: a `frma` box naming the format, the `alac` box, and a box of size zero, as
    /// QuickTime's `wave` box has them.
    static func magicCookie(alac box: BlockBufferReader) -> BlockBufferReader? {
        guard let config = try? box.getBytes(at: MP4Box.headerSize, length: box.readableBytes - MP4Box.headerSize) else {
            return nil
        }
        let cookie = BlockBufferReader.box(type: .frma, payload: MP4Box.BoxType.alac.rawValue.bigEndianBytes)
            + BlockBufferReader.box(type: .alac, payload: config)
            + BlockBufferReader.terminatorBox
        return try? BlockBufferReader(bytes: cookie)
    }

    private static func sourceBitDepthFlags(bitDepth: Int) -> AudioFormatFlags {
        switch bitDepth {
        case 16: kAppleLosslessFormatFlag_16BitSourceData
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        case 32: kAppleLosslessFormatFlag_32BitSourceData
        default: 0
        }
    }
}
