//
//  BoxParser+SampleEntryFormats.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import SEPlayerCommon

extension BoxParser {
    /// The codec string of RFC 6381 of a video codec read from a sample entry of `sampleEntryType`.
    static func videoCodecs(_ codec: VideoCodec, sampleEntryType: MP4Box.BoxType) -> String? {
        let usesParameterSetsInBand = sampleEntryType == .hev1 || sampleEntryType == .dvhe
        switch codec.mimeType {
        case .videoH264:
            return codec.h264.codecs()
        case .videoH265:
            return codec.hevc.codecs(sampleEntryType: usesParameterSetsInBand ? .hev1 : .hvc1)
        case .videoDolbyVision:
            let type: MP4Box.BoxType = switch codec.dolbyVision.baseLayer {
            case .videoH264?: sampleEntryType == .dvav ? .dvav : .dva1
            case .videoAV1?: .dav1
            default: usesParameterSetsInBand ? .dvhe : .dvh1
            }
            return codec.dolbyVision.codecs(sampleEntryType: type)
        case .videoAV1:
            return codec.av1.codecs
        case .videoVP9,
             .videoVP8:
            return codec.vp9.codecs(sampleEntryType: codec.mimeType == .videoVP8 ? .vp08 : .vp09)
        default:
            return nil
        }
    }

    /// The codec string of RFC 6381 of audio codecs that have one besides MPEG-4 audio, whose descriptor gives it.
    static func audioCodecs(_ codec: AudioCodec) -> String? {
        switch codec.mimeType {
        case .audioAC3: "ac-3"
        case .audioEAC3,
             .audioEAC3JOC: "ec-3"
        case .audioALAC: "alac"
        case .audioFLAC: "fLaC"
        case .audioOPUS: "Opus"
        case .audioAPAC: codec.apac.codecs ?? "apac"
        default: nil
        }
    }

    /// The size of the length before each NAL unit of the samples of a codec of NAL units, or 0 for others.
    static func nalUnitLengthSize(_ codec: VideoCodec) -> Int {
        switch codec.mimeType {
        case .videoH264:
            codec.h264.nalUnitLengthSize ?? 0
        case .videoH265:
            codec.hevc.nalUnitLengthSize ?? 0
        case .videoDolbyVision:
            codec.dolbyVision.baseLayer == .videoH264
                ? codec.h264.nalUnitLengthSize ?? 0
                : codec.hevc.nalUnitLengthSize ?? 0
        default:
            0
        }
    }
}
