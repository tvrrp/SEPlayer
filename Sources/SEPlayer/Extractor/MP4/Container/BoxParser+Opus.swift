//
//  BoxParser+Opus.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.07.2025.
//

import AudioToolbox
import CoreMedia

extension BoxParser {
    struct OpusData: Format.InitializationData {
        private let formatDescription: CMAudioFormatDescription

        init?(parent: inout ByteBuffer) throws {
            let version = try parent.readInt(as: UInt8.self)
            guard version == 0 else { return nil }
            let outputChannelCount = try parent.readInt(as: UInt8.self)
            let preSkip = try parent.readInt(as: UInt16.self)
            let inputSampleRate = try parent.readInt(as: UInt32.self)
            let outputGain = try parent.readInt(as: UInt16.self)
            let channelMappingFamily = try parent.readInt(as: UInt8.self)

            guard channelMappingFamily == 0 else {
                // AudioToolbox and frieds probably does not support more that 2 channel audio
                return nil
            }

            // Converts the payload of an MP4 `dOps` box to an RFC-7845 `OpusHead` header.
            var newBuffer = ByteBufferAllocator().buffer(capacity: 19)
            newBuffer.writeString("OpusHead")
            newBuffer.writeInteger(UInt8(1))
            newBuffer.writeInteger(outputChannelCount)
            newBuffer.writeInteger(preSkip, endianness: .little)
            newBuffer.writeInteger(inputSampleRate, endianness: .little)
            newBuffer.writeInteger(outputGain, endianness: .little)
            newBuffer.writeInteger(channelMappingFamily)

            var descriptionSize = Int32(MemoryLayout<AudioStreamBasicDescription>.size)
            var description = AudioStreamBasicDescription(
                mSampleRate: 0,
                mFormatID: kAudioFormatOpus,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 0,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 0,
                mBitsPerChannel: 0,
                mReserved: 0
            )

            let (pointer, unmanaged) = newBuffer.withUnsafeReadableBytesWithStorageManagement {
                ($0.baseAddress!, $1)
            }
            unmanaged.retain()
            defer { unmanaged.release() }

            let audioFormatInfoSize = Int32(MemoryLayout<AudioFormatInfo>.size)
            var audioFormatInfo = AudioFormatInfo(
                mASBD: description,
                mMagicCookie: pointer,
                mMagicCookieSize: UInt32(newBuffer.readableBytes)
            )

            var formatListSize: UInt32 = 0
            try AudioFormatGetPropertyInfo(
                kAudioFormatProperty_FormatList,
                UInt32(MemoryLayout<AudioFormatInfo>.size),
                &audioFormatInfo,
                &formatListSize
            ).validate()

            guard formatListSize > 0 else { return nil }

            var rawPtr = UnsafeMutableRawPointer.allocate(
                byteCount: Int(formatListSize),
                alignment: MemoryLayout<AudioFormatListItem>.alignment
            )
            let formatListPtr = rawPtr.bindMemory(
                to: AudioFormatListItem.self,
                capacity: Int(formatListSize) / MemoryLayout<AudioFormatListItem>.size
            )

            try try withUnsafePointer(to: audioFormatInfo) { pointer in
                AudioFormatGetProperty(
                    kAudioFormatProperty_FormatList,
                    UInt32(audioFormatInfoSize),
                    pointer,
                    &formatListSize,
                    formatListPtr
                )
            }.validate()

            let managedAudioChannelLayout = ManagedAudioChannelLayout(tag: formatListPtr.pointee.mChannelLayoutTag)
            formatDescription = try CMFormatDescription(
                audioStreamBasicDescription: formatListPtr.pointee.mASBD,
                layout: managedAudioChannelLayout,
                magicCookie: Data(buffer: newBuffer, byteTransferStrategy: .copy)
            )
            rawPtr.deallocate()
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }
    }
}
