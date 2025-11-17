//
//  MimeTypes.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.06.2025.
//

enum MimeTypes: String {
    // MARK: - Video
    case videoMP4 = "video/mp4"
    case videoMatroska = "video/x-matroska"
    case videoWebM = "video/webm"
    case videoH263 = "video/3gpp"
    case videoH264 = "video/avc"
    case videoAPV = "video/apv"
    case videoH265 = "video/hevc"
    case videoVP8 = "video/x-vnd.on2.vp8"
    case videoVP9 = "video/x-vnd.on2.vp9"
    case videoAV1 = "video/av01"
    case videoMP2T = "video/mp2t"
    case videoMP4V = "video/mp4v-es"
    case videoMPEG = "video/mpeg"
    case videoPS = "video/mp2p"
    case videoMPEG2 = "video/mpeg2"
    case videoVC1 = "video/wvc1"
    case videoDIVX = "video/divx"
    case videoFLV = "video/x-flv"
    case videoDolbyVision = "video/dolby-vision"
    case videoOGG = "video/ogg"
    case videoAVI = "video/x-msvideo"
    case videoMJPEG = "video/mjpeg"
    case videoMP42 = "video/mp42"
    case videoMP43 = "video/mp43"
    case videoMVHEVC = "video/mv-hevc"
    case videoRAW = "video/raw"
    case videoUnknown = "video/x-unknown"

    // MARK: - Audio
    case audioMP4 = "audio/mp4"
    case audioAAC = "audio/mp4a-latm"
    case audioMatroska = "audio/x-matroska"
    case audioWebM = "audio/webm"
    case audioMPEG = "audio/mpeg"
    case audioMPEGL1 = "audio/mpeg-L1"
    case audioMPEGL2 = "audio/mpeg-L2"
    case audioMPEGHMHA1 = "audio/mha1"
    case audioMPEGHMHM1 = "audio/mhm1"
    case audioRAW = "audio/raw"
    case audioALAW = "audio/g711-alaw"
    case audioMLAW = "audio/g711-mlaw"
    case audioAC3 = "audio/ac3"
    case audioEAC3 = "audio/eac3"
    case audioEAC3JOC = "audio/eac3-joc"
    case audioAC4 = "audio/ac4"
    case audioTRUEHD = "audio/true-hd"
    case audioDTS = "audio/vnd.dts"
    case audioDTSHD = "audio/vnd.dts.hd"
    case audioDTSExpress = "audio/vnd.dts.hd;profile=lbr"
    case audioDTSX = "audio/vnd.dts.uhd;profile=p2"
    case audioVORBIS = "audio/vorbis"
    case audioOPUS = "audio/opus"
    case audioAMR = "audio/amr"
    case audioAMRNB = "audio/3gpp"
    case audioAMRWB = "audio/amr-wb"
    case audioFLAC = "audio/flac"
    case audioALAC = "audio/alac"
    case audioMSGSM = "audio/gsm"
    case audioOGG = "audio/ogg"
    case audioWAV = "audio/wav"
    case audioMIDI = "audio/midi"
    case audioIAMF = "audio/iamf"
    case audioExoplayerMIDI = "audio/x-exoplayer-midi"
    case audioUnknown = "audio/x-unknown"

    // MARK: - Text
    case textVTT = "text/vtt"
    case textSSA = "text/x-ssa"
    case textUnknown = "text/x-unknown"

    // MARK: - Application
    case applicationMP4 = "application/mp4"
    case applicationWebM = "application/webm"
    case applicationMatroska = "application/x-matroska"
    case applicationMPD = "application/dash+xml"
    case applicationM3U8 = "application/x-mpegURL"
    case applicationSS = "application/vnd.ms-sstr+xml"
    case applicationID3 = "application/id3"
    case applicationCEA608 = "application/cea-608"
    case applicationCEA708 = "application/cea-708"
    case applicationSubrip = "application/x-subrip"
    case applicationTTML = "application/ttml+xml"
    case applicationTX3G = "application/x-quicktime-tx3g"
    case applicationMP4VTT = "application/x-mp4-vtt"
    case applicationMP4CEA608 = "application/x-mp4-cea-608"
    case applicationVobSub = "application/vobsub"
    case applicationPGS = "application/pgs"
    case applicationSCTE35 = "application/x-scte35"
    case applicationSDP = "application/sdp"
    case applicationCameraMotion = "application/x-camera-motion"
    case applicationDepthMetadata = "application/x-depth-metadata"
    case applicationEMSG = "application/x-emsg"
    case applicationDVBSubs = "application/dvbsubs"
    case applicationEXIF = "application/x-exif"
    case applicationICY = "application/x-icy"
    case applicationAIT = "application/vnd.dvb.ait"
    case applicationRTSP = "application/x-rtsp"
    case applicationMedia3Cues = "application/x-media3-cues"
    case applicationExternallyLoadedImage = "application/x-image-uri"

    // MARK: - Image

    case imageJPEG = "image/jpeg"
    case imageJPEGR = "image/jpeg_r"
    case imagePNG = "image/png"
    case imageHEIF = "image/heif"
    case imageHEIC = "image/heic"
    case imageAVIF = "image/avif"
    case imageBMP = "image/bmp"
    case imageWEBP = "image/webp"
    case imageRAW = "image/raw"

    // MARK: - Codec (non-standard)

    case codecEAC3JOC = "ec+3"
}

extension MimeTypes {
    var isVideo: Bool { self.rawValue.hasPrefix("video") }
    var isAudio: Bool { self.rawValue.hasPrefix("audio") }
    var isImage: Bool { self.rawValue.hasPrefix("image") }
    var isApplication: Bool { self.rawValue.hasPrefix("application") }

    var trackType: TrackType {
        if isVideo {
            return .video
        } else if isAudio {
            return .audio
        } else {
            return .unknown
        }
    }
}

extension Optional where Wrapped == MimeTypes {
    func allSamplesAreSyncSamples(codec: String?) -> Bool {
        switch self {
        case .audioMPEGL1,
             .audioMPEGL2,
             .audioRAW,
             .audioALAW,
             .audioMLAW,
             .audioFLAC,
             .audioAC3,
             .audioEAC3,
             .audioEAC3JOC:
            return true
        case .audioAAC:
            return true // TODO: check for codec type
        default:
            return false
        }
    }
}
