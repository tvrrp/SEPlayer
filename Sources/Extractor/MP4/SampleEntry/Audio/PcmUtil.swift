//
//  PcmUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import SEPlayerCommon

/// Describes linear PCM sample entries: QuickTime's formats, named by their sample type and byte order, and ISO's
/// `ipcm` and `fpcm`, described by a `pcmC` box.
enum PcmUtil {
    /// The QuickTime formats of linear PCM whose fields of version 0 and 1 describe the samples, with the format
    /// `0` of the oldest files.
    static let quickTimeFormats: Set<UInt32> = Set([
        MP4Box.BoxType.NONE, .raw_, .twos, .sowt, .lpcm, .in24, .in32, .fl32, .fl64,
    ].map(\.rawValue) + [0])

    /// The stream description of a QuickTime linear PCM entry of version 0 or 1.
    ///
    /// The format tells the sample type, and for 24 and 32 bit integers and floats their size; `raw ` of 8 bits is
    /// unsigned. Samples are big-endian except `sowt`, and the sizes given by the format unless an `enda` box marks
    /// them little-endian.
    static func streamDescription(
        format rawFormat: UInt32,
        sampleRate: Double,
        channelCount: Int,
        sampleSize: Int,
        isLittleEndian: Bool
    ) -> AudioStreamBasicDescription {
        let format = MP4Box.BoxType(rawValue: rawFormat)
        var flags = kAudioFormatFlagIsPacked
        switch format {
        case .fl32?, .fl64?:
            flags |= kAudioFormatFlagIsFloat
        case nil, .raw_?, .NONE?:
            if sampleSize != 8 { flags |= kAudioFormatFlagIsSignedInteger }
        default:
            flags |= kAudioFormatFlagIsSignedInteger
        }

        switch format {
        case .fl32?, .fl64?, .in24?, .in32?:
            if !isLittleEndian { flags |= kAudioFormatFlagIsBigEndian }
        case .sowt?:
            break
        default:
            flags |= kAudioFormatFlagIsBigEndian
        }

        let bitsPerChannel = switch format {
        case .fl32?, .in32?: 32
        case .fl64?: 64
        case .in24?: 24
        default: sampleSize
        }
        let bytesPerFrame = UInt32(bitsPerChannel / 8 * channelCount)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(bitsPerChannel),
            mReserved: 0
        )
    }

    /// The format flags of a QuickTime version 2 entry of linear PCM, without the ones that contradict each other:
    /// packed samples have no alignment, floats no sign, and the samples of one format are always mixable.
    static func version2Flags(_ flags: AudioFormatFlags) -> AudioFormatFlags {
        var flags = flags
        if flags & kAudioFormatFlagIsPacked != 0 { flags &= ~kAudioFormatFlagIsAlignedHigh }
        if flags & kAudioFormatFlagIsFloat != 0 { flags &= ~(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable) }
        return flags & ~kAudioFormatFlagIsNonMixable
    }

    /// The stream description of an `ipcm` or `fpcm` entry with its `pcmC` box of ISO/IEC 23003-5: integers or
    /// floats, of a size and a byte order the box tells.
    ///
    /// - Parameter box: The whole box, from its size field: version and flags (4), format_flags (1), whose first bit
    ///   marks little-endian samples, and PCM_sample_size (1).
    static func streamDescription(
        pcmC box: BlockBufferReader,
        isFloat: Bool,
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription? {
        guard let formatFlags = try? box.getInt(at: 12, as: UInt8.self),
              let sampleSize = try? box.getInt(at: 13, as: UInt8.self) else {
            return nil
        }
        let isLittleEndian = formatFlags & 0x01 != 0
        let bitsPerChannel = Int(sampleSize)
        guard bitsPerChannel > 0, bitsPerChannel % 8 == 0 else { return nil }

        var flags = kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if !isLittleEndian { flags |= kAudioFormatFlagIsBigEndian }
        let bytesPerFrame = UInt32(bitsPerChannel / 8 * channelCount)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(bitsPerChannel),
            mReserved: 0
        )
    }
}
