//
//  BoxParser+SampleEntryFormats.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import AudioToolbox
import CoreMedia
import QuartzCore
import SEPlayerCommon

extension BoxParser {
    /// The format of an audio track whose sample entry was read into a format description.
    func audioFormat(_ audio: AudioSampleEntryData, trackId: Int, language: String) -> Format {
        let description = audio.streamDescription
        let subtype = CMAudioFormatDescription.MediaSubType(rawValue: description.mFormatID)
        let descriptor = audio.elementaryStreamDescriptor

        let builder = Format.Builder()
            .setId(trackId)
            .setSampleMimeType(descriptor?.audioMimeType ?? subtype.audioMimeType)
            .setCodecs(descriptor?.codecs ?? Self.audioCodecs(subtype))
            .setChannelCount(Int(description.mChannelsPerFrame))
            .setSampleRate(Int(description.mSampleRate))
            .setInitializationData(SampleEntryFormatDescription(formatDescription: audio.formatDescription))
            .setLanguage(language)
        if let descriptor {
            builder
                .setAverageBitrate(descriptor.averageBitrate > 0 ? descriptor.averageBitrate : Format.noValue)
                .setPeakBitrate(descriptor.maxBitrate > 0 ? descriptor.maxBitrate : Format.noValue)
        }
        return builder.build()
    }

    /// The codec string of RFC 6381 of formats that have one besides MPEG-4 audio.
    private static func audioCodecs(_ subtype: CMAudioFormatDescription.MediaSubType) -> String? {
        switch subtype {
        case .ac3: "ac-3"
        case .enhancedAC3: "ec-3"
        case .appleLossless: "alac"
        case .flac: "fLaC"
        case .opus: "Opus"
        default: MP4Box.BoxType(rawValue: subtype.rawValue) == .apac ? "apac" : nil
        }
    }
}

extension BoxParser {
    /// The format of a video track whose sample entry was read into a format description, for codecs without a
    /// config read here.
    func videoFormat(
        _ video: VideoSampleEntryData,
        trackId: Int,
        codecs: String?,
        pixelWidthHeightRatio: Float,
        rotationDegrees: CGFloat,
        transform3D: CATransform3D,
        videoRange: Format.VideoRange
    ) -> Format {
        let subtype = CMVideoFormatDescription.MediaSubType(rawValue: video.codecType)
        var ratio = pixelWidthHeightRatio
        if let aspect = video.formatDescription.extensionValue(for: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
           let horizontal = (aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.floatValue,
           let vertical = (aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.floatValue,
           horizontal > 0, vertical > 0 {
            ratio = horizontal / vertical
        }
        return Format.Builder()
            .setId(trackId)
            .setSampleMimeType(subtype.videoMimeType)
            .setCodecs(codecs)
            .setSize(width: video.width, height: video.height)
            .setPixelWidthHeightRatio(ratio)
            .setRotationDegrees(rotationDegrees)
            .setTransform3D(transform3D)
            .setInitializationData(SampleEntryFormatDescription(formatDescription: video.formatDescription))
            .setMaxSubLayers(.zero)
            .setVideoRange(videoRange)
            .build()
    }
}
