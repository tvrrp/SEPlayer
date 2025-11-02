//
//  BoxParser+ESDescriptor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import AudioToolbox.AudioFormat
import CoreMedia.CMFormatDescription

extension BoxParser {
    struct EsdsData: Format.InitializationData {
        let mimeType: MimeTypes?
        let bitrate: Int
        let peakBitrate: Int
        private let formatDescription: CMAudioFormatDescription

        init(parent: inout ByteBuffer, position: Int, size: Int) throws {
            parent.moveReaderIndex(to: position + MP4Box.headerSize + 4)
            let data = try parent.slice(at: parent.readerIndex, length: size - MP4Box.fullHeaderSize)

            // Start of the ES_Descriptor (defined in ISO/IEC 14496-1)
            parent.moveReaderIndex(forwardBy: 1) // ES_Descriptor tag
            try EsdsData.parseExpandableClassSize(data: &parent)
            parent.moveReaderIndex(forwardBy: 2) // ES_ID

            let flags = try parent.readInt(as: UInt8.self)
            if (flags & 0x80) != 0 { // streamDependenceFlag
                parent.moveReaderIndex(forwardBy: 2)
            }
            if (flags & 0x40) != 0 { // URL_Flag
                try parent.moveReaderIndex(forwardBy: Int(parent.readInt(as: UInt8.self)))
            }
            if (flags & 0x20) != 0 { // OCRstreamFlag
                parent.moveReaderIndex(forwardBy: 2)
            }

            // Start of the DecoderConfigDescriptor (defined in ISO/IEC 14496-1)
            parent.moveReaderIndex(forwardBy: 1) // DecoderConfigDescriptor tag
            try EsdsData.parseExpandableClassSize(data: &parent)

            // Set the MIME type based on the object type indication (ISO/IEC 14496-1 table 5).
            let objectTypeIndication = try parent.readInt(as: UInt8.self)
            mimeType = .audioAAC
            // TODO MimeType from objectTypeIndication

            parent.moveReaderIndex(forwardBy: 4)
            peakBitrate = try Int(parent.readInt(as: UInt32.self))
            bitrate = try Int(parent.readInt(as: UInt32.self))

            // Start of the DecoderSpecificInfo.
            parent.moveReaderIndex(forwardBy: 1) // DecoderSpecificInfo tag
            let initializationDataSize = try EsdsData.parseExpandableClassSize(data: &parent)
            let initializationData = try parent.readData(count: initializationDataSize)

            formatDescription = try ESDescriptor(esdt: Data(buffer: data)).codecInfo
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }

        @discardableResult
        private static func parseExpandableClassSize(data: inout ByteBuffer) throws -> Int {
            var currentByte = try data.readInt(as: UInt8.self)
            var size = currentByte & 0x7F
            while (currentByte & 0x80) == 0x80 {
                currentByte = try data.readInt(as: UInt8.self)
                size = (size << 7) | (currentByte & 0x7F)
            }
            return Int(size)
        }
    }

    struct ESDescriptor {
        let codecInfo: CMAudioFormatDescription

        init(esdt payload: Data) throws {
            var description = AudioStreamBasicDescription()
            var descriptionSize = Int32(MemoryLayout<AudioStreamBasicDescription>.size)

            try payload.withUnsafeBytes { pointer in
                return AudioFormatGetProperty(
                    kAudioFormatProperty_ASBDFromESDS,
                    UInt32(payload.count),
                    pointer.baseAddress,
                    &descriptionSize,
                    &description
                )
            }.validate()

            let audioFormatDescription = try? payload.withUnsafeBytes { dataPointer in
                guard let baseAdress = dataPointer.baseAddress else {
                    throw ErrorBuilder.illegalState
                }

                let audioFormatInfoSize = Int32(MemoryLayout<AudioFormatInfo>.size)
                var audioFormatInfo = AudioFormatInfo(
                    mASBD: description,
                    mMagicCookie: baseAdress,
                    mMagicCookieSize: UInt32(payload.count)
                )

                var formatListSize: UInt32 = 0
                try AudioFormatGetPropertyInfo(
                    kAudioFormatProperty_FormatList,
                    UInt32(MemoryLayout<AudioFormatInfo>.size),
                    &audioFormatInfo,
                    &formatListSize
                ).validate()

                guard formatListSize > 0 else { throw ErrorBuilder.illegalState }

                let elementCount = Int(formatListSize) / MemoryLayout<AudioFormatListItem>.size
                var formatListArray = Array(repeating: AudioFormatListItem(), count: elementCount)

                try withUnsafePointer(to: audioFormatInfo) { pointer in
                    AudioFormatGetProperty(
                        kAudioFormatProperty_FormatList,
                        UInt32(audioFormatInfoSize),
                        pointer,
                        &formatListSize,
                        &formatListArray
                    )
                }.validate()

                guard formatListSize > 0 else { throw ErrorBuilder.illegalState }
                let count = Int(formatListSize) / MemoryLayout<AudioFormatListItem>.size

                let descriptions = try formatListArray[0..<count].map {
                    try CMAudioFormatDescription(
                        audioStreamBasicDescription: $0.mASBD,
                        layout: .init(tag: $0.mChannelLayoutTag),
                        magicCookie: payload
                    )
                }

//                return try CMAudioFormatDescription(audioFormatDescriptionArray: descriptions)
                return descriptions[0] // TODO: do smth
            }

            codecInfo = if let audioFormatDescription {
                audioFormatDescription
            } else {
                try CMAudioFormatDescription(
                    audioStreamBasicDescription: description,
                    magicCookie: payload
                )
            }

//            var layoutSize: UInt32 = 0
//            try payload.withUnsafeBytes { pointer in
//                return AudioFormatGetPropertyInfo(
//                    kAudioFormatProperty_ChannelLayoutFromESDS,
//                    UInt32(payload.count),
//                    pointer.baseAddress,
//                    &layoutSize
//                )
//            }.validate()
//
//            let rawPtr = UnsafeMutableRawPointer.allocate(
//                byteCount: Int(layoutSize),
//                alignment: MemoryLayout<AudioChannelLayout>.alignment
//            )
//            let channelLayoutPtr = rawPtr.bindMemory(to: AudioChannelLayout.self, capacity: 1)
//
//            try payload.withUnsafeBytes { pointer in
//                return AudioFormatGetProperty(
//                    kAudioFormatProperty_ChannelLayoutFromESDS,
//                    UInt32(payload.count),
//                    pointer.baseAddress,
//                    &layoutSize,
//                    channelLayoutPtr
//                )
//            }.validate()
//
//            let managedAudioChannelLayout: ManagedAudioChannelLayout
//            if channelLayoutPtr.pointee.mNumberChannelDescriptions == .zero {
//                managedAudioChannelLayout = ManagedAudioChannelLayout(tag: channelLayoutPtr.pointee.mChannelLayoutTag)
//                rawPtr.deallocate()
//            } else {
//                managedAudioChannelLayout = ManagedAudioChannelLayout.init(
//                    audioChannelLayoutPointer: .init(channelLayoutPtr),
//                    deallocator: { _ in
//                        rawPtr.deallocate()
//                    }
//                )
//            }
//
//            codecInfo = try CMAudioFormatDescription(
//                audioStreamBasicDescription: description,
//                layout: managedAudioChannelLayout,
//                magicCookie: payload
//            )
        }
    }
}
