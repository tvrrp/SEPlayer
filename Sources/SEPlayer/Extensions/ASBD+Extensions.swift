//
//  ASBD+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.04.2025.
//

import CoreAudioTypes

extension AudioStreamBasicDescription {
    enum CommonPCMFormats {
        case pcmFloat32
        case pcmInt16
        case pcmFixed824
    }

    // from CAStreamBasicDescription
    init(format: CommonPCMFormats, sampleRate: Double, numOfChannels: UInt32, isInterleaved: Bool = true) {
        let wordsize: UInt32

        let mFormatID = kAudioFormatLinearPCM
        var mFormatFlags: AudioFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        let mFramesPerPacket: UInt32 = 1
        var mBytesPerFrame: UInt32 = 0
        var mBytesPerPacket: UInt32 = 0

        switch format {
        case .pcmFloat32:
            wordsize = 4
            mFormatFlags |= kAudioFormatFlagIsFloat
        case .pcmInt16:
            wordsize = 2
            mFormatFlags |= kAudioFormatFlagIsSignedInteger
        case .pcmFixed824:
            wordsize = 4
            mFormatFlags |= kAudioFormatFlagIsSignedInteger | (24 << kLinearPCMFormatFlagsSampleFractionShift)
        }
        let mBitsPerChannel = wordsize * 8

        if isInterleaved {
            mBytesPerFrame = wordsize * numOfChannels
            mBytesPerPacket = wordsize * numOfChannels
        } else {
            mFormatFlags |= kAudioFormatFlagIsNonInterleaved
            mBytesPerFrame = wordsize
            mBytesPerPacket = wordsize
        }

        self.init(
            mSampleRate: sampleRate,
            mFormatID: mFormatID,
            mFormatFlags: mFormatFlags,
            mBytesPerPacket: mBytesPerPacket,
            mFramesPerPacket: mFramesPerPacket,
            mBytesPerFrame: mBytesPerFrame,
            mChannelsPerFrame: numOfChannels,
            mBitsPerChannel: mBitsPerChannel,
            mReserved: 0
        )
    }
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
            && lhs.mReserved == rhs.mReserved
    }
}
