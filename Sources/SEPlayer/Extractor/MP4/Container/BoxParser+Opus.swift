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

            try withUnsafePointer(to: audioFormatInfo) { pointer in
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

//
//extension BoxParser {
//    struct OpusData: Format.InitializationData {
//        let outputChannelCount: Int
//        let preSkip: Int
//        let inputSampleRate: Int
//        let outputGain: Int
//        let channelMapping: ChannelMapping
//
//        private let formatDescription: CMAudioFormatDescription
//
//        init?(parent: inout ByteBuffer, size: Int) throws {
//            let version = try Int(reading: &parent, type: UInt8.self)
//            guard version == 0 else { return nil }
//
//            var slice = try parent.slice(length: size - 1)
//            outputChannelCount = try Int(reading: &slice, type: UInt8.self)
//            preSkip = try Int(reading: &slice, type: UInt16.self)
//            inputSampleRate = try Int(reading: &slice, type: UInt32.self)
//            outputGain = try Int(reading: &slice, type: UInt16.self)
//            let channelMappingFamily = try Int(reading: &slice, type: UInt8.self)
//
//            channelMapping = if channelMappingFamily != 0 {
//                try ChannelMapping(
//                    parent: &slice,
//                    outputChannelCount: Int(outputChannelCount)
//                )
//            } else {
//                ChannelMapping(outputChannelCount: outputChannelCount)
//            }
//
//            // Convert the payload of an MP4 `dOps` box to an RFC-7845 5.5.1 `OpusHead` header.
//            slice.moveReaderIndex(to: 0)
//            var magicCookie = ByteBuffer()
//            magicCookie.writeString("OpusHead")
//            magicCookie.writeInteger(UInt8(1))
//            magicCookie.writeBuffer(&slice)
//
//            var description = AudioStreamBasicDescription()
//            description.mSampleRate = Float64(inputSampleRate)
//            description.mFormatID = kAudioFormatOpus
//            description.mChannelsPerFrame = UInt32(outputChannelCount)
//
//            let channelTag: AudioChannelLayoutTag
//            switch outputChannelCount {
//            case 1:
//                channelTag = kAudioChannelLayoutTag_Mono
//            case 2:
//                channelTag = kAudioChannelLayoutTag_Stereo
//            default:
//                guard channelMappingFamily == 1 else { return nil } // See RFC-7845 5.1.1.3
//                switch outputChannelCount {
//                case 3:
//                    channelTag = kAudioChannelLayoutTag_Ogg_3_0
//                case 4:
//                    channelTag = kAudioChannelLayoutTag_Ogg_4_0
//                case 5:
//                    channelTag = kAudioChannelLayoutTag_Ogg_5_0
//                case 6:
//                    channelTag = kAudioChannelLayoutTag_Ogg_5_1
//                case 7:
//                    channelTag = kAudioChannelLayoutTag_Ogg_6_1
//                case 8:
//                    channelTag = kAudioChannelLayoutTag_Ogg_7_1
//                default:
//                    return nil
//                }
//            }
//
//            formatDescription = try CMFormatDescription(
//                audioStreamBasicDescription: description,
//                layout: ManagedAudioChannelLayout(tag: channelTag)
////                magicCookie: Data(buffer: magicCookie, byteTransferStrategy: .copy)
//            )
//        }
//
//        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
//            formatDescription
//        }
//
//        /// See RFC-7845 5.1.1 Channel Mapping
//        struct ChannelMapping: Hashable {
//            let streamCount: Int
//            let coupledCount: Int
//            let channelMapping: [Int]
//
//            init(parent: inout ByteBuffer, outputChannelCount: Int) throws {
//                streamCount = try Int(reading: &parent, type: UInt8.self)
//                coupledCount = try Int(reading: &parent, type: UInt8.self)
//                channelMapping = try (0..<outputChannelCount).map { _ in
//                    try Int(reading: &parent, type: UInt8.self)
//                }
//            }
//
//            init(outputChannelCount: Int) {
//                self.streamCount = 1
//                self.coupledCount = outputChannelCount - 1
//                self.channelMapping = outputChannelCount > 1 ? [0, 1] : [0]
//            }
//        }
//    }
//}
//
