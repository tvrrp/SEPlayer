//
//  Codecs.swift
//  SEPlayer
//
//  Portions of this file are derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.MimeTypes
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation

/// RFC 6381 codec strings, as in an HLS `CODECS` attribute.
public enum Codecs {
    /// Splits a codecs string, such as `"avc1.64001f,mp4a.40.2"`, into its codecs.
    public static func split(_ codecs: String?) -> [String] {
        guard let codecs, !codecs.isEmpty else { return [] }
        return codecs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `codecs` spelled as the system's playability check knows them.
    ///
    /// A codec that carries its parameter sets in the samples (`avc3`, `hev1`, `dvav`, `dvhe`) is named by its twin
    /// that carries them in the sample entry (`avc1`, `hvc1`, `dva1`, `dvh1`): they decode the same once the parameter
    /// sets are known. MP3 is named `mp3`, as the check rejects its MP4 names such as `mp4a.40.34`.
    public static func forPlayabilityQuery(_ codecs: String) -> String {
        let twins = ["avc3": "avc1", "hev1": "hvc1", "dvav": "dva1", "dvhe": "dvh1"]
        return split(codecs).map { codec in
            if mediaMimeType(forCodec: codec) == .audioMPEG { return "mp3" }
            let entry = codec.prefix(4).lowercased()
            guard let twin = twins[entry] else { return codec }
            return twin + codec.dropFirst(4)
        }.joined(separator: ",")
    }

    /// The codec string of a sample MIME type whose codec has one, for a format that doesn't give its codecs.
    public static func codec(forSampleMimeType mimeType: MimeTypes) -> String? {
        switch mimeType {
        case .audioAAC: "mp4a.40.2"
        case .audioMPEGL1: "mp4a.40.32"
        case .audioMPEGL2: "mp4a.40.33"
        case .audioAC3: "ac-3"
        case .audioEAC3,
             .audioEAC3JOC: "ec-3"
        case .audioAC4: "ac-4"
        case .audioDTS: "dtsc"
        case .audioDTSHD: "dtsh"
        case .audioDTSExpress: "dtse"
        case .audioDTSX: "dtsx"
        case .audioTRUEHD: "mlpa"
        case .audioMPEGHMHA1: "mha1"
        case .audioMPEGHMHM1: "mhm1"
        case .audioALAC: "alac"
        case .audioFLAC: "fLaC"
        case .audioOPUS: "opus"
        default: nil
        }
    }

    /// The codecs of `codecs` that are of `trackType`, joined again, or `nil` if there are none.
    public static func ofType(_ codecs: String?, trackType: TrackType) -> String? {
        let matching = split(codecs).filter { mediaMimeType(forCodec: $0).trackType == trackType }
        return matching.isEmpty ? nil : matching.joined(separator: ",")
    }

    /// The sample MIME type of the first codec of a comma-separated list that is of `trackType`.
    public static func mediaMimeType(ofType trackType: TrackType, in codecs: String?) -> MimeTypes? {
        split(codecs).lazy.compactMap(mediaMimeType(forCodec:)).first { $0.trackType == trackType }
    }

    /// The sample MIME type for a codec, or `nil` if it isn't known.
    public static func mediaMimeType(forCodec codec: String) -> MimeTypes? {
        let codec = codec.trimmingCharacters(in: .whitespaces).lowercased()
        if codec.hasPrefix("avc1") || codec.hasPrefix("avc3") {
            return .videoH264
        } else if codec.hasPrefix("hev1") || codec.hasPrefix("hvc1") {
            return .videoH265
        } else if codec.hasPrefix("dvav") || codec.hasPrefix("dva1") || codec.hasPrefix("dvhe")
            || codec.hasPrefix("dvh1") || codec.hasPrefix("dav1") {
            return .videoDolbyVision
        } else if codec.hasPrefix("av01") {
            return .videoAV1
        } else if codec.hasPrefix("vp9") || codec.hasPrefix("vp09") {
            return .videoVP9
        } else if codec.hasPrefix("vp8") || codec.hasPrefix("vp08") {
            return .videoVP8
        } else if codec.hasPrefix("mp4a") {
            return mp4aMimeType(codec)
        } else if codec.hasPrefix("ac-3") || codec.hasPrefix("dac3") {
            return .audioAC3
        } else if codec.hasPrefix("ec-3") || codec.hasPrefix("dec3") {
            return .audioEAC3
        } else if codec.hasPrefix(MimeTypes.codecEAC3JOC.rawValue) {
            return .audioEAC3JOC
        } else if codec.hasPrefix("ac-4") || codec.hasPrefix("dac4") {
            return .audioAC4
        } else if codec.hasPrefix("dtsc") {
            return .audioDTS
        } else if codec.hasPrefix("dtse") {
            return .audioDTSExpress
        } else if codec.hasPrefix("dtsh") || codec.hasPrefix("dtsl") {
            return .audioDTSHD
        } else if codec.hasPrefix("dtsx") {
            return .audioDTSX
        } else if codec.hasPrefix("opus") {
            return .audioOPUS
        } else if codec.hasPrefix("vorbis") {
            return .audioVORBIS
        } else if codec.hasPrefix("flac") {
            return .audioFLAC
        } else if codec.hasPrefix("alac") {
            return .audioALAC
        } else if codec.hasPrefix("apac") {
            return .audioAPAC
        } else if codec.hasPrefix("stpp") {
            return .applicationTTML
        } else if codec.hasPrefix("wvtt") {
            return .textVTT
        }
        return nil
    }

    /// `mp4a.<object type>[.<audio object type>]`, with the object types in hexadecimal and decimal.
    private static func mp4aMimeType(_ codec: String) -> MimeTypes {
        let parts = codec.split(separator: ".")
        guard parts.count >= 2, let objectType = Int(parts[1], radix: 16) else {
            return .audioAAC
        }
        switch objectType {
        case 0x40:
            // MPEG-4 audio: the audio object types of MPEG-1 layers 1 to 3 aren't AAC.
            switch parts.count > 2 ? Int(parts[2]) : nil {
            case 32: return .audioMPEGL1
            case 33: return .audioMPEGL2
            case 34: return .audioMPEG
            default: return .audioAAC
            }
        case 0x69,
             0x6B: return .audioMPEG
        case 0xA5: return .audioAC3
        case 0xA6: return .audioEAC3
        case 0xA9,
             0xAC: return .audioDTS
        case 0xAA,
             0xAB: return .audioDTSHD
        case 0xAD: return .audioOPUS
        case 0xAE: return .audioAC4
        default: return .audioAAC
        }
    }
}
