//
//  VideoCodec.swift
//  SEPlayer
//

import Foundation

/// A video codec, named by its MIME type, with the attributes of its bitstream.
///
/// The attributes of each codec are in a scope of their own: `codec.h264.sequenceParameterSets`,
/// `codec.av1.configurationOBUs`. A codec that builds on another one has the attributes of both: Dolby Vision has its
/// own and those of its base layer, and HEVC with a Dolby Vision layer other decoders may leave aside has those of
/// the layer.
@dynamicMemberLookup
public struct VideoCodec: Hashable, Sendable, CustomStringConvertible, CodecStorage {
    /// The scopes of the codecs that have attributes.
    public struct Scopes {
        public let h263 = H263.self
        public let h264 = H264.self
        public let hevc = HEVC.self
        public let vp8 = VP.self
        public let vp9 = VP.self
        public let av1 = AV1.self
        public let apv = APV.self
        public let mpegVideo = MPEGVideo.self
        public let mpeg4Visual = MPEG4Visual.self
        public let vc1 = VC1.self
        public let proRes = ProRes.self
        public let dolbyVision = DolbyVision.self
    }

    public var mimeType: MimeTypes

    public var description: String { codecDescription }

    var storage = AttributeStorage()

    public init(_ mimeType: MimeTypes) {
        self.mimeType = mimeType
    }

    /// A codec of `mimeType` with the attributes of one scope.
    public init<S: FormatAttributeScope>(
        _ mimeType: MimeTypes,
        _ scope: KeyPath<Scopes, S.Type>,
        _ configure: (inout CodecAttributes<S>) throws -> Void
    ) rethrows {
        self.init(mimeType)
        try setAttributes(CodecAttributes<S>(configure))
    }

    public subscript<S: FormatAttributeScope>(dynamicMember keyPath: KeyPath<Scopes, S.Type>) -> CodecAttributes<S> {
        get { attributes(S.self) }
        set { setAttributes(newValue) }
    }

    public static func h264(_ configure: (inout CodecAttributes<H264>) throws -> Void) rethrows -> VideoCodec {
        try VideoCodec(.videoH264, \.h264, configure)
    }

    public static func hevc(_ configure: (inout CodecAttributes<HEVC>) throws -> Void) rethrows -> VideoCodec {
        try VideoCodec(.videoH265, \.hevc, configure)
    }

    public static func av1(_ configure: (inout CodecAttributes<AV1>) throws -> Void) rethrows -> VideoCodec {
        try VideoCodec(.videoAV1, \.av1, configure)
    }

    public static func dolbyVision(_ configure: (inout CodecAttributes<DolbyVision>) throws -> Void) rethrows -> VideoCodec {
        try VideoCodec(.videoDolbyVision, \.dolbyVision, configure)
    }
}

// MARK: - H.264

public extension VideoCodec {
    /// H.264: what an `AVCDecoderConfigurationRecord` of ISO/IEC 14496-15 carries.
    struct H264: FormatAttributeScope {
        /// `profile_idc`.
        public struct Profile: RawRepresentable, Hashable, Sendable {
            public static let baseline = Profile(rawValue: 66)
            public static let main = Profile(rawValue: 77)
            public static let extended = Profile(rawValue: 88)
            public static let high = Profile(rawValue: 100)
            public static let high10 = Profile(rawValue: 110)
            public static let high422 = Profile(rawValue: 122)
            public static let high444Predictive = Profile(rawValue: 244)

            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        /// `level_idc`: ten times the level, so 31 is level 3.1.
        public struct Level: RawRepresentable, Hashable, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        public let profile = FormatAttribute<Profile>("profile")
        /// The `constraint_set` flags, the byte between the profile and the level.
        public let constraintFlags = FormatAttribute<UInt8>("constraintFlags")
        public let level = FormatAttribute<Level>("level")
        /// Each a whole NAL unit from its header, with emulation prevention bytes.
        public let sequenceParameterSets = FormatAttribute<[Data]>("sequenceParameterSets")
        public let pictureParameterSets = FormatAttribute<[Data]>("pictureParameterSets")
        public let sequenceParameterSetExtensions = FormatAttribute<[Data]>("sequenceParameterSetExtensions")
        /// The size in bytes of the length before each NAL unit of a sample.
        public let nalUnitLengthSize = FormatAttribute<Int>("nalUnitLengthSize")
        public let chromaFormat = FormatAttribute<ChromaFormat>("chromaFormat")
        public let bitDepthLuma = FormatAttribute<Int>("bitDepthLuma")
        public let bitDepthChroma = FormatAttribute<Int>("bitDepthChroma")
        /// Whether samples carry their own parameter sets, as an `avc3` track does.
        public let hasInBandParameterSets = DefaultedFormatAttribute<Bool>("hasInBandParameterSets", default: false)

        public init() {}
    }
}

// MARK: - HEVC

public extension VideoCodec {
    /// HEVC: what an `HEVCDecoderConfigurationRecord` of ISO/IEC 14496-15 carries.
    struct HEVC: FormatAttributeScope {
        public enum Tier: Int, Hashable, Sendable {
            case main = 0
            case high
        }

        /// `general_profile_idc`.
        public struct Profile: RawRepresentable, Hashable, Sendable {
            public static let main = Profile(rawValue: 1)
            public static let main10 = Profile(rawValue: 2)
            public static let mainStillPicture = Profile(rawValue: 3)
            public static let rangeExtensions = Profile(rawValue: 4)

            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        /// `general_level_idc`: thirty times the level, so 153 is level 5.1.
        public struct Level: RawRepresentable, Hashable, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        public struct NALUnitType: RawRepresentable, Hashable, Sendable {
            public static let videoParameterSet = NALUnitType(rawValue: 32)
            public static let sequenceParameterSet = NALUnitType(rawValue: 33)
            public static let pictureParameterSet = NALUnitType(rawValue: 34)
            public static let prefixSEI = NALUnitType(rawValue: 39)
            public static let suffixSEI = NALUnitType(rawValue: 40)

            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        public struct NALUnitArray: Hashable, Sendable {
            public var type: NALUnitType
            /// Whether every unit of the type is here, and none is in the samples.
            public var isComplete: Bool
            /// Each a whole NAL unit from its header, with emulation prevention bytes.
            public var units: [Data]

            public init(type: NALUnitType, isComplete: Bool = true, units: [Data]) {
                self.type = type
                self.isComplete = isComplete
                self.units = units
            }
        }

        public let profileSpace = FormatAttribute<Int>("profileSpace")
        public let tier = FormatAttribute<Tier>("tier")
        public let profile = FormatAttribute<Profile>("profile")
        /// The flag of profile 0 in the highest bit, as the record writes them.
        public let profileCompatibilityFlags = FormatAttribute<UInt32>("profileCompatibilityFlags")
        /// The 48 constraint indicator flags.
        public let constraintIndicatorFlags = FormatAttribute<UInt64>("constraintIndicatorFlags")
        public let level = FormatAttribute<Level>("level")
        public let minSpatialSegmentation = FormatAttribute<Int>("minSpatialSegmentation")
        public let parallelismType = FormatAttribute<Int>("parallelismType")
        public let chromaFormat = FormatAttribute<ChromaFormat>("chromaFormat")
        public let bitDepthLuma = FormatAttribute<Int>("bitDepthLuma")
        public let bitDepthChroma = FormatAttribute<Int>("bitDepthChroma")
        /// In frames per 256 seconds, 0 when unknown.
        public let averageFrameRate = FormatAttribute<Int>("averageFrameRate")
        public let constantFrameRate = FormatAttribute<Int>("constantFrameRate")
        /// The number of temporal sub-layers, or 0 when the record doesn't tell.
        public let temporalLayerCount = FormatAttribute<Int>("temporalLayerCount")
        public let isTemporalIDNested = FormatAttribute<Bool>("isTemporalIDNested")
        /// The size in bytes of the length before each NAL unit of a sample.
        public let nalUnitLengthSize = FormatAttribute<Int>("nalUnitLengthSize")
        /// The parameter sets and SEI messages, by type, in the order of the record.
        public let nalUnitArrays = FormatAttribute<[NALUnitArray]>("nalUnitArrays")
        /// Whether samples carry their own parameter sets, as a `hev1` track does.
        public let hasInBandParameterSets = DefaultedFormatAttribute<Bool>("hasInBandParameterSets", default: false)

        public init() {}
    }
}

public extension CodecAttributes where Scope == VideoCodec.HEVC {
    var videoParameterSets: [Data] { units(of: .videoParameterSet) }
    var sequenceParameterSets: [Data] { units(of: .sequenceParameterSet) }
    var pictureParameterSets: [Data] { units(of: .pictureParameterSet) }

    func units(of type: VideoCodec.HEVC.NALUnitType) -> [Data] {
        (self.nalUnitArrays ?? []).filter { $0.type == type }.flatMap(\.units)
    }
}

// MARK: - AV1

public extension VideoCodec {
    /// AV1: what an `AV1CodecConfigurationRecord` of the AV1 ISOBMFF binding carries.
    struct AV1: FormatAttributeScope {
        public enum Profile: Int, Hashable, Sendable {
            case main = 0
            case high
            case professional
        }

        public enum Tier: Int, Hashable, Sendable {
            case main = 0
            case high
        }

        /// `seq_level_idx`: 0 is level 2.0, 8 is level 4.0, 13 is level 5.1.
        public struct Level: RawRepresentable, Hashable, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        public enum ChromaSamplePosition: Int, Hashable, Sendable {
            case unknown = 0
            case vertical
            case colocated
        }

        public let profile = FormatAttribute<Profile>("profile")
        /// `seq_level_idx` of operating point 0.
        public let level = FormatAttribute<Level>("level")
        public let tier = FormatAttribute<Tier>("tier")
        public let bitDepth = FormatAttribute<Int>("bitDepth")
        public let chromaFormat = FormatAttribute<ChromaFormat>("chromaFormat")
        public let chromaSamplePosition = FormatAttribute<ChromaSamplePosition>("chromaSamplePosition")
        /// The frames a decoder needs before it can show the first one.
        public let initialPresentationDelay = FormatAttribute<Int>("initialPresentationDelay")
        /// The sequence header OBU, then metadata OBUs.
        public let configurationOBUs = FormatAttribute<Data>("configurationOBUs")

        public init() {}
    }
}

// MARK: - VP8 and VP9

public extension VideoCodec {
    /// VP8 and VP9: what a `VPCodecConfigurationRecord` of the VP ISOBMFF binding carries.
    struct VP: FormatAttributeScope {
        public enum ChromaSubsampling: Int, Hashable, Sendable {
            case yuv420Vertical = 0
            case yuv420Colocated
            case yuv422
            case yuv444
        }

        public let profile = FormatAttribute<Int>("profile")
        /// Ten times the level, so 31 is level 3.1.
        public let level = FormatAttribute<Int>("level")
        public let bitDepth = FormatAttribute<Int>("bitDepth")
        public let chromaSubsampling = FormatAttribute<ChromaSubsampling>("chromaSubsampling")
        /// The colour the bitstream declares, which the record repeats.
        public let isFullRange = FormatAttribute<Bool>("isFullRange")
        public let colorPrimaries = FormatAttribute<ColorPrimaries>("colorPrimaries")
        public let transferFunction = FormatAttribute<TransferFunction>("transferFunction")
        public let matrixCoefficients = FormatAttribute<MatrixCoefficients>("matrixCoefficients")
        public let codecInitializationData = FormatAttribute<Data>("codecInitializationData")

        public init() {}
    }
}

// MARK: - Dolby Vision

public extension VideoCodec {
    /// Dolby Vision: what a `DOVIDecoderConfigurationRecord` carries. The attributes of the base layer are in the
    /// scope of its codec.
    struct DolbyVision: FormatAttributeScope {
        public let versionMajor = FormatAttribute<Int>("versionMajor")
        public let versionMinor = FormatAttribute<Int>("versionMinor")
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")
        public let hasReferenceProcessingUnit = FormatAttribute<Bool>("hasReferenceProcessingUnit")
        public let hasEnhancementLayer = FormatAttribute<Bool>("hasEnhancementLayer")
        public let hasBaseLayer = FormatAttribute<Bool>("hasBaseLayer")
        /// What decoders without Dolby Vision can show of the base layer: 0 nothing, 1 HDR10, 2 SDR, 4 HLG.
        public let baseLayerSignalCompatibilityID = FormatAttribute<Int>("baseLayerSignalCompatibilityID")
        /// The codec of the base layer.
        public let baseLayer = FormatAttribute<MimeTypes>("baseLayer")

        public init() {}
    }
}

public extension CodecAttributes where Scope == VideoCodec.DolbyVision {
    /// Whether decoders without Dolby Vision show the base layer: every profile but 5, whose IPTPQc2 only Dolby
    /// Vision shows.
    var isBaseLayerCompatible: Bool {
        self.profile != 5 && self.baseLayerSignalCompatibilityID != 0
    }
}

// MARK: - Other codecs

public extension VideoCodec {
    /// H.263: what a `d263` box carries.
    struct H263: FormatAttributeScope {
        /// The vendor of the encoder.
        public let vendor = FormatAttribute<FourCharacterCode>("vendor")
        public let decoderVersion = FormatAttribute<Int>("decoderVersion")
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")

        public init() {}
    }

    /// APV: what an `APVDecoderConfigurationRecord` carries.
    struct APV: FormatAttributeScope {
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")
        public let band = FormatAttribute<Int>("band")
        public let bitDepth = FormatAttribute<Int>("bitDepth")
        public let chromaFormat = FormatAttribute<ChromaFormat>("chromaFormat")

        public init() {}
    }

    /// MPEG-1 and MPEG-2 video.
    struct MPEGVideo: FormatAttributeScope {
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")
        /// The sequence header and its extension.
        public let sequenceHeader = FormatAttribute<Data>("sequenceHeader")

        public init() {}
    }

    /// MPEG-4 Part 2.
    struct MPEG4Visual: FormatAttributeScope {
        public let profileAndLevel = FormatAttribute<Int>("profileAndLevel")
        /// The visual object sequence and video object layer headers.
        public let decoderSpecificInfo = FormatAttribute<Data>("decoderSpecificInfo")

        public init() {}
    }

    /// VC-1: what a `dvc1` box carries.
    struct VC1: FormatAttributeScope {
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")
        public let sequenceHeader = FormatAttribute<Data>("sequenceHeader")

        public init() {}
    }

    struct ProRes: FormatAttributeScope {
        public enum Variant: Hashable, Sendable {
            case proxy
            case lt
            case standard
            case hq
            case p4444
            case p4444XQ
            case raw
            case rawHQ
        }

        public let variant = FormatAttribute<Variant>("variant")
        /// The bits of each pixel the sample entry declares: 32 for 4444 with alpha.
        public let depth = FormatAttribute<Int>("depth")

        public init() {}
    }
}
