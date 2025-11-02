//
//  BoxParser+CoreMediaParsers.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.10.2025.
//

import CoreMedia
import QuartzCore

extension BoxParser {
    struct CoreMediaParsedAudio: Format.InitializationData {
        private let formatDescription: CMFormatDescription

        static func create(
            parent: inout ByteBuffer,
            position: Int,
            size: Int,
            trackId: Int,
            language: String,
            isQuickTime: Bool,
            out: inout StsdData2,
            entryIndex: Int
        ) throws -> Bool {
            return false // TODO: remove
            parent.moveReaderIndex(to: position)
            var formatDescriptionOut: CMAudioFormatDescription?

            let result = try parent.withUnsafeReadableBytes { pointer in
                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
                    guard let baseAdress = buffer.baseAddress else {
                        throw ErrorBuilder.illegalState
                    }

                    return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
                        allocator: kCFAllocatorDefault,
                        bigEndianSoundDescriptionData: baseAdress,
                        size: buffer.count,
                        flavor: isQuickTime ? .quickTimeMovieV2 : .isoFamily,
                        formatDescriptionOut: &formatDescriptionOut
                    )
                }
            }

            guard let formatDescriptionOut, let basicDescription = formatDescriptionOut.audioStreamBasicDescription else { return false }
            let initializationData = CoreMediaParsedAudio(formatDescription: formatDescriptionOut)

            if out.format == nil {
                let formatBuilder = Format.Builder()
                    .setId(trackId)
//                    .setSampleMimeType(mimeType)
//                    .setCodecs(codecs)
                    .setChannelCount(Int(basicDescription.mChannelsPerFrame))
                    .setSampleRate(Int(basicDescription.mSampleRate))
    //                .setPcmEncoding(pcmEncoding)
                    .setInitializationData(initializationData)
                    .setLanguage(language)

                out.format = formatBuilder.build()
            }

            return out.format != nil
        }

        private init(formatDescription: CMFormatDescription) {
            self.formatDescription = formatDescription
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }
    }

    struct CoreMediaParsedVideo: Format.InitializationData {
        private let formatDescription: CMFormatDescription

        static func create(
            parent: inout ByteBuffer,
            position: Int,
            size: Int,
            trackId: Int,
            rotationDegrees: CGFloat,
            transform3D: CATransform3D,
            isQuickTime: Bool,
            out: inout StsdData2,
            entryIndex: Int
        ) throws -> Bool {
            parent.moveReaderIndex(to: position)
            var formatDescriptionOut: CMVideoFormatDescription?

            try parent.withUnsafeReadableBytes { pointer in
                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
                    guard let baseAdress = buffer.baseAddress else {
                        throw ErrorBuilder.illegalState
                    }

                    return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                        allocator: kCFAllocatorDefault,
                        bigEndianImageDescriptionData: baseAdress,
                        size: buffer.count,
                        stringEncoding: CFStringGetSystemEncoding(),
                        flavor: isQuickTime ? .quickTimeMovie : .isoFamily,
                        formatDescriptionOut: &formatDescriptionOut
                    )
                }
            }.validate()

            guard let formatDescriptionOut else { return false }
            let initializationData = CoreMediaParsedVideo(formatDescription: formatDescriptionOut)

            if out.format == nil {
                let formatBuilder = Format.Builder()
                    .setId(trackId)
                    .setSampleMimeType(.videoH264)
//                    .setCodecs(nil)
//                    .setSize(width: Int(width), height: Int(height))
//                    .setPixelWidthHeightRatio(pixelWidthHeightRatio)
                    .setRotationDegrees(rotationDegrees)
                    .setTransform3D(transform3D)
                    .setInitializationData(initializationData)
//                    .setMaxNumReorderSamples(maxNumReorderSamples)
                    .setMaxSubLayers(.zero)

                out.format = formatBuilder.build()
            }

            return out.format != nil
        }

        private init(formatDescription: CMFormatDescription) {
            self.formatDescription = formatDescription
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }
    }
}
