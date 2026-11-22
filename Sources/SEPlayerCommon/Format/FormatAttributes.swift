//
//  FormatAttributes.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.Format
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation

/// The scopes of the attributes of formats.
public enum FormatAttributes {
    /// Attributes every format can have.
    public struct Common: FormatAttributeScope {
        public let id = FormatAttribute<String>("id")
        public let label = FormatAttribute<String>("label")
        public let labels = DefaultedFormatAttribute<[String]>("labels", default: [])
        public let language = FormatAttribute<String>("language")
        public let selectionFlags = DefaultedFormatAttribute<SelectionFlags>("selectionFlags", default: [])
        public let roleFlags = DefaultedFormatAttribute<RoleFlags>("roleFlags", default: [])
        public let averageBitrate = FormatAttribute<Int>("averageBitrate")
        public let peakBitrate = FormatAttribute<Int>("peakBitrate")
        /// The codecs as RFC 6381 writes them, the way a playlist or a container declares them.
        public let codecs = FormatAttribute<String>("codecs")
        /// The codec of an enhancement layer that decoders which support it play instead of ``codecs``, such as a
        /// Dolby Vision layer on an HEVC base: the first codec of an HLS `SUPPLEMENTAL-CODECS` attribute.
        public let supplementalCodecs = FormatAttribute<String>("supplementalCodecs")
        public let containerMimeType = FormatAttribute<MimeTypes>("containerMimeType")
        /// Static metadata of the track: tags of the container or the stream, such as titles, artwork or ICY headers.
        public let metadata = FormatAttribute<SEPlayerCommon.Metadata>("metadata")
        /// The sample entry the format was read from, whole, when a container had one.
        public let sampleEntry = FormatAttribute<SampleEntry>("sampleEntry")
        /// The boxes an ISO base media file describes the samples with, in the order of its sample entry: the
        /// configuration of the codec, such as `avcC` or `esds`, and what else the entry tells.
        ///
        /// Formats of every source have them: a stream outside such a file, as in MPEG-TS, gets the configuration
        /// box its codec has there, written from its own headers. Each platform makes its decoder's format of them.
        public let boxes = DefaultedFormatAttribute<[MediaBox]>("boxes", default: [])
        /// The protection of the samples, when a Common Encryption scheme protects them.
        public let encryption = FormatAttribute<CommonEncryption>("encryption")
        public init() {}
    }

    public struct Video: MediaAttributeScope {
        public static let trackType = TrackType.video
        public let codec = FormatAttribute<VideoCodec>("codec")
        /// The type of the sample entry that names the codec, such as `hev1`, when the container names it.
        public let codecType = FormatAttribute<FourCharacterCode>("codecType")
        public let size = FormatAttribute<VideoSize>("size")
        public let frameRate = FormatAttribute<Float>("frameRate")
        /// Clockwise rotation to show the video upright, in degrees.
        public let rotation = DefaultedFormatAttribute<Int>("rotation", default: 0)
        /// The frames a decoder may hold back to reorder.
        public let maxReorderFrames = FormatAttribute<Int>("maxReorderFrames")
        public let colorPrimaries = FormatAttribute<ColorPrimaries>("colorPrimaries")
        public let transferFunction = FormatAttribute<TransferFunction>("transferFunction")
        public let matrixCoefficients = FormatAttribute<MatrixCoefficients>("matrixCoefficients")
        public let isFullRange = FormatAttribute<Bool>("isFullRange")
        /// The transfer function displays that know it use instead of ``transferFunction``.
        public let alternativeTransferFunction = FormatAttribute<TransferFunction>("alternativeTransferFunction")
        /// The gamma of a picture whose transfer function is a power law.
        public let gammaLevel = FormatAttribute<Double>("gammaLevel")
        public let iccProfile = FormatAttribute<Data>("iccProfile")
        /// The name of a log transfer function, such as Apple Log.
        public let logTransferFunction = FormatAttribute<String>("logTransferFunction")
        public let chromaLocationTopField = FormatAttribute<ChromaLocation>("chromaLocationTopField")
        public let chromaLocationBottomField = FormatAttribute<ChromaLocation>("chromaLocationBottomField")
        public let bitsPerComponent = FormatAttribute<Int>("bitsPerComponent")
        public let masteringDisplay = FormatAttribute<MasteringDisplay>("masteringDisplay")
        public let contentLightLevel = FormatAttribute<ContentLightLevel>("contentLightLevel")
        public let ambientViewingEnvironment = FormatAttribute<AmbientViewingEnvironment>("ambientViewingEnvironment")
        public let contentColorVolume = FormatAttribute<ContentColorVolume>("contentColorVolume")

        /// The spacing of pixels, exact, as ``size`` has its ratio.
        public let pixelAspectRatio = FormatAttribute<PixelAspectRatio>("pixelAspectRatio")
        public let cleanAperture = FormatAttribute<CleanAperture>("cleanAperture")
        /// 1 for progressive pictures, 2 for interlaced ones.
        public let fieldCount = FormatAttribute<Int>("fieldCount")
        public let fieldOrder = FormatAttribute<FieldOrder>("fieldOrder")
        /// The bytes of a row of uncompressed pictures.
        public let bytesPerRow = FormatAttribute<Int>("bytesPerRow")
        public let alphaChannelMode = FormatAttribute<AlphaChannelMode>("alphaChannelMode")
        public let containsAlphaChannel = FormatAttribute<Bool>("containsAlphaChannel")

        /// The fields of the sample entry before its boxes.
        public let sampleEntryFields = FormatAttribute<VisualSampleEntryFields>("sampleEntryFields")
        /// The format that names the MPEG-2 profile, such as `xdv7` for XDCAM.
        public let mpeg2Profile = FormatAttribute<FourCharacterCode>("mpeg2Profile")

        /// In thousandths of a degree.
        public let horizontalFieldOfView = FormatAttribute<Int>("horizontalFieldOfView")
        public let stereoViews = FormatAttribute<StereoViews>("stereoViews")
        public let heroEye = FormatAttribute<HeroEye>("heroEye")
        /// The distance between the cameras, in micrometers.
        public let stereoCameraBaseline = FormatAttribute<UInt32>("stereoCameraBaseline")
        /// In ten-thousandths of the width of the picture.
        public let horizontalDisparityAdjustment = FormatAttribute<Int32>("horizontalDisparityAdjustment")
        /// The identifier of the camera that carries the views of a camera system.
        public let transportIdentifier = FormatAttribute<UInt32>("transportIdentifier")
        public let projection = FormatAttribute<VideoProjection>("projection")
        public let viewPacking = FormatAttribute<ViewPacking>("viewPacking")
        /// The boxes of the video extended usage a reader must understand and that weren't read, each by its path
        /// of types from `vexu` on.
        public let unrecognizedRequiredBoxPaths = FormatAttribute<[[FourCharacterCode]]>("unrecognizedRequiredBoxPaths")
        public init() {}
    }

    public struct Audio: MediaAttributeScope {
        public static let trackType = TrackType.audio
        public let codec = FormatAttribute<AudioCodec>("codec")
        public let sampleRate = FormatAttribute<Int>("sampleRate")
        public let channelCount = FormatAttribute<Int>("channelCount")
        public let channelLayout = FormatAttribute<ChannelLayout>("channelLayout")
        /// Frames a decoder outputs before the first one of the audio.
        public let encoderDelay = DefaultedFormatAttribute<Int>("encoderDelay", default: 0)
        /// Frames a decoder outputs after the last one of the audio.
        public let encoderPadding = DefaultedFormatAttribute<Int>("encoderPadding", default: 0)
        public init() {}
    }

    public struct Text: MediaAttributeScope {
        public static let trackType = TrackType.text
        public let codec = FormatAttribute<TextCodec>("codec")
        public let cueReplacementBehavior = DefaultedFormatAttribute<CueReplacementBehavior>(
            "cueReplacementBehavior",
            default: .merge
        )
        /// The time cues of the samples are relative to, in seconds; `nil` when they are relative to their sample.
        public let subsampleOffset = FormatAttribute<TimeInterval>("subsampleOffset")
        public init() {}
    }

    public struct Metadata: MediaAttributeScope {
        public static let trackType = TrackType.metadata
        /// The format of the samples, such as ID3 or event messages.
        public let codec = FormatAttribute<MimeTypes>("codec")
        public init() {}
    }

    /// The scope of a format whose media is known only at run time.
    public struct AnyMedia: FormatAttributeScope {
        public init() {}
    }
}

// MARK: - Video values

/// Colour primaries, as a code point of ITU-T H.273.
public struct ColorPrimaries: RawRepresentable, Hashable, Sendable {
    public static let bt709 = ColorPrimaries(rawValue: 1)
    public static let unspecified = ColorPrimaries(rawValue: 2)
    public static let bt601NTSC = ColorPrimaries(rawValue: 6)
    public static let bt2020 = ColorPrimaries(rawValue: 9)
    public static let dciP3 = ColorPrimaries(rawValue: 11)
    public static let displayP3 = ColorPrimaries(rawValue: 12)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Transfer characteristics, as a code point of ITU-T H.273.
public struct TransferFunction: RawRepresentable, Hashable, Sendable {
    public static let bt709 = TransferFunction(rawValue: 1)
    public static let unspecified = TransferFunction(rawValue: 2)
    public static let sRGB = TransferFunction(rawValue: 13)
    public static let pq = TransferFunction(rawValue: 16)
    public static let hlg = TransferFunction(rawValue: 18)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Matrix coefficients, as a code point of ITU-T H.273.
public struct MatrixCoefficients: RawRepresentable, Hashable, Sendable {
    public static let identity = MatrixCoefficients(rawValue: 0)
    public static let bt709 = MatrixCoefficients(rawValue: 1)
    public static let unspecified = MatrixCoefficients(rawValue: 2)
    public static let bt601 = MatrixCoefficients(rawValue: 6)
    public static let bt2020NonConstant = MatrixCoefficients(rawValue: 9)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// The colour volume of the mastering display, as SMPTE ST 2086 writes it.
public struct MasteringDisplay: Hashable, Sendable {
    /// Chromaticity of green, blue, red and the white point, x then y, in units of 0.00002.
    public var chromaticities: [UInt16]
    /// In units of 0.0001 candelas per square metre.
    public var maximumLuminance: UInt32
    public var minimumLuminance: UInt32

    public init(chromaticities: [UInt16], maximumLuminance: UInt32, minimumLuminance: UInt32) {
        self.chromaticities = chromaticities
        self.maximumLuminance = maximumLuminance
        self.minimumLuminance = minimumLuminance
    }
}

/// The content light level of HDR video, in candelas per square metre.
public struct ContentLightLevel: Hashable, Sendable {
    public var maximumContentLightLevel: Int
    public var maximumFrameAverageLightLevel: Int

    public init(maximumContentLightLevel: Int, maximumFrameAverageLightLevel: Int) {
        self.maximumContentLightLevel = maximumContentLightLevel
        self.maximumFrameAverageLightLevel = maximumFrameAverageLightLevel
    }
}

/// How chroma is sampled, as `chroma_format_idc` numbers it.
public enum ChromaFormat: Int, Hashable, Sendable {
    case monochrome = 0
    case yuv420
    case yuv422
    case yuv444
}

/// The dynamic range of a video.
public enum VideoRange: Int, Hashable, Sendable, Comparable {
    case sdr = 1
    /// Hybrid log-gamma: HDR that SDR displays can show.
    case hlg
    /// Perceptual quantizer: HDR10, HDR10+ and Dolby Vision.
    case pq

    /// The range of an HLS `VIDEO-RANGE` attribute, or `nil` for a value it doesn't define.
    public init?(hlsAttribute value: String) {
        switch value.uppercased() {
        case "SDR": self = .sdr
        case "HLG": self = .hlg
        case "PQ": self = .pq
        default: return nil
        }
    }

    public static func < (lhs: VideoRange, rhs: VideoRange) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension Format where Scope == FormatAttributes.Video {
    /// The dynamic range the transfer function gives, or `nil` when it is not known.
    var videoRange: VideoRange? {
        switch self.transferFunction {
        case .pq?: .pq
        case .hlg?: .hlg
        case .unspecified?,
             nil: nil
        default: .sdr
        }
    }
}

// MARK: - Audio values

/// The channels of audio, in the order of the samples.
public struct ChannelLayout: Hashable, Sendable {
    public enum Channel: Hashable, Sendable {
        case left
        case right
        case center
        case lowFrequency
        /// The surrounds of 5.1, at the sides or behind.
        case leftSurround
        case rightSurround
        /// The rear pair of 7.1.
        case leftRearSurround
        case rightRearSurround
        case centerSurround
        case leftCenter
        case rightCenter
        case leftTopFront
        case rightTopFront
        case centerTopFront
        case leftTopRear
        case rightTopRear
        case centerTopRear
        case topCenterSurround
        case leftWide
        case rightWide
        case lowFrequency2
    }

    public static let mono = ChannelLayout([.center])
    public static let stereo = ChannelLayout([.left, .right])

    public var channels: [Channel]

    public init(_ channels: [Channel]) {
        self.channels = channels
    }
}

// MARK: - Text values

/// The replacement behaviors for consecutive samples of cues.
public enum CueReplacementBehavior: Hashable, Sendable {
    /// Cues from each sample are shown until they are cleared, as by an empty sample, or their duration elapses.
    ///
    /// Cues may be shown at the same time as cues from previous or later samples, if they overlap.
    case merge
    /// Cues from each sample are shown until the next sample, or their duration elapses, whichever is sooner.
    ///
    /// If a sample has no explicit duration, its cues are shown until the next sample.
    case replace
}
