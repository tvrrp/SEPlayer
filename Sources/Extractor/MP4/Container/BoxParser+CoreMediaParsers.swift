//
//  BoxParser+CoreMediaParsers.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.10.2025.
//

import CoreMedia
import QuartzCore
import SEPlayerCommon

extension BoxParser {
    struct CoreMediaParsedAudio: Format.InitializationData {
        private let formatDescription: CMFormatDescription

        static func create(
            parent: inout BlockBufferReader,
            position: Int,
            size: Int,
            trackId: Int,
            language: String,
            isQuickTime: Bool,
            out: inout StsdData2,
            entryIndex: Int
        ) throws -> Bool {
//            return false // TODO: remove
            parent.moveReaderIndex(to: position)
            var formatDescriptionOut: CMAudioFormatDescription?

            try parent.withUnsafeReadableBlockBuffer { blockBuffer in
                return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionBlockBuffer(
                    allocator: kCFAllocatorDefault,
                    bigEndianSoundDescriptionBlockBuffer: blockBuffer,
                    flavor: isQuickTime ? .quickTimeMovieV2 : .isoFamily,
                    formatDescriptionOut: &formatDescriptionOut
                )
            }.validate()
//            try parent.withUnsafeReadableBytes { pointer in
//                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
//                    guard let baseAdress = buffer.baseAddress else {
//                        throw ErrorBuilder.illegalState
//                    }
//
//                    return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
//                        allocator: kCFAllocatorDefault,
//                        bigEndianSoundDescriptionData: baseAdress,
//                        size: buffer.count,
//                        flavor: isQuickTime ? .quickTimeMovieV2 : .isoFamily,
//                        formatDescriptionOut: &formatDescriptionOut
//                    )
//                }
//            }.validate()

            guard let formatDescriptionOut, let basicDescription = formatDescriptionOut.audioStreamBasicDescription else { return false }
            let initializationData = CoreMediaParsedAudio(formatDescription: formatDescriptionOut)

            if out.format == nil {
                let formatBuilder = Format.Builder()
                    .setId(trackId)
                    .setSampleMimeType(sampleMimeType(from: formatDescriptionOut))
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
            parent: inout BlockBufferReader,
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

//            try parent.withUnsafeReadableBytes { pointer in
//                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
//                    guard let baseAdress = buffer.baseAddress else {
//                        throw ErrorBuilder.illegalState
//                    }
//
//                    return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
//                        allocator: kCFAllocatorDefault,
//                        bigEndianImageDescriptionData: baseAdress,
//                        size: buffer.count,
//                        stringEncoding: CFStringGetSystemEncoding(),
//                        flavor: isQuickTime ? .quickTimeMovie : .isoFamily,
//                        formatDescriptionOut: &formatDescriptionOut
//                    )
//                }
//            }.validate()
            try parent.withUnsafeReadableBlockBuffer { blockBuffer in
                return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionBlockBuffer(
                    allocator: kCFAllocatorDefault,
                    bigEndianImageDescriptionBlockBuffer: blockBuffer,
                    stringEncoding: CFStringGetSystemEncoding(),
                    flavor: isQuickTime ? .quickTimeMovie : .isoFamily,
                    formatDescriptionOut: &formatDescriptionOut
                )
            }.validate()

            guard let formatDescriptionOut else { return false }
            let initializationData = CoreMediaParsedVideo(formatDescription: formatDescriptionOut)

            if out.format == nil {
                let formatBuilder = Format.Builder()
                    .setId(trackId)
                    .setSampleMimeType(sampleMimeType(from: formatDescriptionOut))
//                    .setCodecs(nil)
//                    .setPixelWidthHeightRatio(pixelWidthHeightRatio)
                    .setRotationDegrees(rotationDegrees)
                    .setTransform3D(transform3D)
                    .setInitializationData(initializationData)
//                    .setMaxNumReorderSamples(maxNumReorderSamples)
                    .setMaxSubLayers(.zero)

                if formatDescriptionOut.dimensions.width != .zero,
                   formatDescriptionOut.dimensions.height != .zero {
                    formatBuilder.setSize(
                        width: Int(formatDescriptionOut.dimensions.width),
                        height: Int(formatDescriptionOut.dimensions.height)
                    )
                }

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

    private static func sampleMimeType(from formatDescription: CMFormatDescription) -> MimeTypes? {
        switch formatDescription.mediaType {
        case .video:
            return videoSampleMimeType(from: formatDescription)
        case .audio:
            return audioSampleMimeType(from: formatDescription)
        default:
            return nil
        }
    }

    private static func videoSampleMimeType(from formatDescription: CMVideoFormatDescription) -> MimeTypes? {
        switch formatDescription.mediaSubType {
        case .h263:
            return .videoH263
        case .h264:
            return .videoH264
        case .hevc, .hevcWithAlpha:
            return .videoH265
        default:
            switch formatDescription.mediaSubType.rawValue {
            case kCMVideoCodecType_VP9:
                return .videoVP9
            case kCMVideoCodecType_AV1:
                return .videoAV1
            default:
                return nil
            }
        }
    }

    private static func audioSampleMimeType(from formatDescription: CMVideoFormatDescription) -> MimeTypes? {
        switch formatDescription.mediaSubType {
        case .mpeg4AAC:
            return .audioAAC
        case .opus:
            return .audioOPUS
        case .flac:
            return .audioFLAC
        default:
            return nil
        }
    }
}
