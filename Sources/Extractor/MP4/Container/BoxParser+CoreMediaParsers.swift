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
            let formatDescriptionOut = try parent.withUnsafeReadableBlockBuffer { blockBuffer in
                try CMAudioFormatDescription(
                    bigEndianSoundDescription: blockBuffer,
                    flavor: isQuickTime ? .quickTimeMovieV2 : .isoFamily
                )
            }
//            try parent.withUnsafeReadableBytes { pointer in
//                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
//                    guard let baseAdress = buffer.baseAddress else {
//                        throw ErrorBuilder.illegalState()
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

            guard let basicDescription = formatDescriptionOut.audioStreamBasicDescription else {
                return false
            }
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

//            try parent.withUnsafeReadableBytes { pointer in
//                try pointer.withMemoryRebound(to: UInt8.self) { buffer in
//                    guard let baseAdress = buffer.baseAddress else {
//                        throw ErrorBuilder.illegalState()
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
            let formatDescriptionOut = try parent.withUnsafeReadableBlockBuffer { blockBuffer in
                try CMVideoFormatDescription(
                    bigEndianImageDescription: blockBuffer,
                    flavor: isQuickTime ? .quickTimeMovie : .isoFamily
                )
            }
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

        /// The system's description of a whole sample entry, its indices starting at 0.
        init(entry: BlockBufferReader, isQuickTime: Bool) throws {
            formatDescription = try entry.withUnsafeReadableBlockBuffer { blockBuffer in
                try CMVideoFormatDescription(
                    bigEndianImageDescription: blockBuffer,
                    flavor: isQuickTime ? .quickTimeMovie : .isoFamily
                )
            }
        }

        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
            formatDescription
        }
    }

    private static func sampleMimeType(from formatDescription: CMFormatDescription) -> MimeTypes? {
        switch formatDescription.mediaType {
        case .video:
            formatDescription.mediaSubType.videoMimeType
        case .audio:
            formatDescription.mediaSubType.audioMimeType
        default:
            nil
        }
    }
}

extension CMVideoFormatDescription.MediaSubType {
    /// The sample MIME type of the format, or `nil` for one that has none of its own.
    var videoMimeType: MimeTypes? {
        switch self {
        case .h263:
            return .videoH263
        case .h264:
            return .videoH264
        case .hevc,
             .hevcWithAlpha:
            return .videoH265
        case .mpeg4Video:
            return .videoMP4V
        case .mpeg2Video:
            return .videoMPEG2
        case .mpeg1Video:
            return .videoMPEG
        case .jpeg,
             .jpeg_OpenDML:
            return .videoMJPEG
        default:
            break
        }

        // A format made from a sample entry keeps the entry's type: `avc3` and `hev1` carry their parameter sets in
        // the samples, and the codecs without a subtype of their own have only the entry's.
        guard let sampleEntry = MP4Box.BoxType(rawValue: rawValue) else {
            return nil
        }
        switch sampleEntry {
        // Protected media is named by its codec and scheme.
        case .avc3,
             .cavc,
             .qavc,
             .qave:
            return .videoH264
        case .hev1,
             .chvc,
             .qhvc,
             .qhev:
            return .videoH265
        case .cdh1,
             .qdh1,
             .qdhe,
             .dav1,
             .qdav:
            return .videoDolbyVision
        case .qav1:
            return .videoAV1
        case .qvp9:
            return .videoVP9
        case .s263,
             .H263:
            return .videoH263
        case .m1v_:
            return .videoMPEG
        case .dvav,
             .dva1,
             .dvhe,
             .dvh1:
            return .videoDolbyVision
        case .vp08:
            return .videoVP8
        case .vp09:
            return .videoVP9
        case .av01:
            return .videoAV1
        default:
            return nil
        }
    }
}

extension CMAudioFormatDescription.MediaSubType {
    /// The sample MIME type of the format, or `nil` for one that has none of its own.
    var audioMimeType: MimeTypes? {
        switch self {
        case .linearPCM:
            return .audioRAW
        // Every AAC profile, USAC (xHE-AAC) and the protected AAC formats share the AAC MIME type.
        case .mpeg4AAC,
             .mpeg4AAC_HE,
             .mpeg4AAC_HE_V2,
             .mpeg4AAC_LD,
             .mpeg4AAC_ELD,
             .mpeg4AAC_ELD_SBR,
             .mpeg4AAC_ELD_V2,
             .mpeg4AAC_Spatial,
             .mpegD_USAC,
             .aacLCProtected,
             .aacAudibleProtected:
            return .audioAAC
        case .ac3,
             .iec60958AC3:
            return .audioAC3
        case .enhancedAC3:
            return .audioEAC3
        case .mpegLayer1:
            return .audioMPEGL1
        case .mpegLayer2:
            return .audioMPEGL2
        case .mpegLayer3:
            return .audioMPEG
        case .uLaw:
            return .audioMLAW
        case .aLaw:
            return .audioALAW
        case .amr:
            return .audioAMRNB
        case .amr_WB:
            return .audioAMRWB
        case .appleLossless:
            return .audioALAC
        case .flac:
            return .audioFLAC
        case .opus:
            return .audioOPUS
        case .microsoftGSM:
            return .audioMSGSM
        default:
            break
        }

        // Protected media is named by its codec, and APAC has no subtype of its own.
        switch MP4Box.BoxType(rawValue: rawValue) {
        case .qaac?: return .audioAAC
        case .qac3?: return .audioAC3
        case .qec3?: return .audioEAC3
        case .qlac?: return .audioALAC
        case .qflc?: return .audioFLAC
        case .apac?,
             .qapc?: return .audioAPAC
        default: return nil
        }
    }
}
