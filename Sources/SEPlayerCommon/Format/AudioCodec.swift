//
//  AudioCodec.swift
//  SEPlayer
//

import Foundation

/// An audio codec, named by its MIME type, with the attributes of its bitstream: `codec.aac.audioSpecificConfig`,
/// `codec.opus.preSkip`.
@dynamicMemberLookup
public struct AudioCodec: Hashable, Sendable, CustomStringConvertible, CodecStorage {
    /// The scopes of the codecs that have attributes.
    public struct Scopes {
        public let aac = AAC.self
        public let mpegH = MPEGH.self
        public let ac3 = AC3.self
        public let eac3 = EAC3.self
        public let ac4 = AC4.self
        public let trueHD = TrueHD.self
        public let dts = DTS.self
        public let opus = Opus.self
        public let vorbis = Vorbis.self
        public let flac = FLAC.self
        public let alac = ALAC.self
        public let pcm = PCM.self
        public let amr = AMR.self
        public let iamf = IAMF.self
        public let apac = APAC.self
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

    public static func aac(_ configure: (inout CodecAttributes<AAC>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioAAC, \.aac, configure)
    }

    public static func ac3(_ configure: (inout CodecAttributes<AC3>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioAC3, \.ac3, configure)
    }

    /// Enhanced AC-3, named with joint object coding when the attributes say the stream has it.
    public static func eac3(_ configure: (inout CodecAttributes<EAC3>) throws -> Void) rethrows -> AudioCodec {
        let attributes = try CodecAttributes<EAC3>(configure)
        let mimeType: MimeTypes = attributes.jointObjectCodingComplexity == nil ? .audioEAC3 : .audioEAC3JOC
        return AudioCodec(mimeType, \.eac3) { $0 = attributes }
    }

    public static func opus(_ configure: (inout CodecAttributes<Opus>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioOPUS, \.opus, configure)
    }

    public static func flac(_ configure: (inout CodecAttributes<FLAC>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioFLAC, \.flac, configure)
    }

    public static func alac(_ configure: (inout CodecAttributes<ALAC>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioALAC, \.alac, configure)
    }

    public static func pcm(_ configure: (inout CodecAttributes<PCM>) throws -> Void) rethrows -> AudioCodec {
        try AudioCodec(.audioRAW, \.pcm, configure)
    }
}

// MARK: - AAC

public extension AudioCodec {
    /// MPEG-4 audio: what an `AudioSpecificConfig` of ISO/IEC 14496-3 carries.
    struct AAC: FormatAttributeScope {
        /// The audio object type.
        public struct ObjectType: RawRepresentable, Hashable, Sendable {
            public static let main = ObjectType(rawValue: 1)
            public static let lowComplexity = ObjectType(rawValue: 2)
            public static let spectralBandReplication = ObjectType(rawValue: 5)
            public static let lowDelay = ObjectType(rawValue: 23)
            public static let parametricStereo = ObjectType(rawValue: 29)
            public static let mpeg1Layer1 = ObjectType(rawValue: 32)
            public static let mpeg1Layer2 = ObjectType(rawValue: 33)
            public static let enhancedLowDelay = ObjectType(rawValue: 39)
            public static let usac = ObjectType(rawValue: 42)

            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }
        }

        /// The object type of the core coder.
        public let objectType = FormatAttribute<ObjectType>("objectType")
        /// The rate of the core coder, which spectral band replication doubles.
        public let coreSampleRate = FormatAttribute<Int>("coreSampleRate")
        public let extensionSampleRate = FormatAttribute<Int>("extensionSampleRate")
        public let channelConfiguration = FormatAttribute<Int>("channelConfiguration")
        public let hasSpectralBandReplication = DefaultedFormatAttribute<Bool>("hasSpectralBandReplication", default: false)
        public let hasParametricStereo = DefaultedFormatAttribute<Bool>("hasParametricStereo", default: false)
        /// Samples per frame: 1024 or 960, and 512 or 480 for low delay.
        public let frameLength = FormatAttribute<Int>("frameLength")
        /// The config as the stream declares it, which decoders take as it is.
        public let audioSpecificConfig = FormatAttribute<Data>("audioSpecificConfig")

        public init() {}
    }
}

// MARK: - Dolby

public extension AudioCodec {
    /// AC-3: what a `dac3` box of ETSI TS 102 366 carries.
    struct AC3: FormatAttributeScope {
        /// `fscod`: 0 is 48000 Hz, 1 is 44100 Hz, 2 is 32000 Hz.
        public let sampleRateCode = FormatAttribute<Int>("sampleRateCode")
        public let bitstreamID = FormatAttribute<Int>("bitstreamID")
        public let bitstreamMode = FormatAttribute<Int>("bitstreamMode")
        /// `acmod`: which full range channels there are.
        public let audioCodingMode = FormatAttribute<Int>("audioCodingMode")
        public let hasLowFrequencyEffects = FormatAttribute<Bool>("hasLowFrequencyEffects")
        public let bitRateCode = FormatAttribute<Int>("bitRateCode")

        public init() {}
    }

    /// Enhanced AC-3: what a `dec3` box of ETSI TS 102 366 carries.
    struct EAC3: FormatAttributeScope {
        /// An independent substream.
        public struct Substream: Hashable, Sendable {
            /// `fscod`: 0 is 48000 Hz, 1 is 44100 Hz, 2 is 32000 Hz.
            public var sampleRateCode: Int
            public var bitstreamID: Int
            public var isAudioServiceMixed: Bool
            public var bitstreamMode: Int
            public var audioCodingMode: Int
            public var hasLowFrequencyEffects: Bool
            public var dependentSubstreamCount: Int
            /// `chan_loc`: the channels the dependent substreams add.
            public var channelLocations: Int

            public init(
                sampleRateCode: Int,
                bitstreamID: Int,
                isAudioServiceMixed: Bool = false,
                bitstreamMode: Int,
                audioCodingMode: Int,
                hasLowFrequencyEffects: Bool,
                dependentSubstreamCount: Int = 0,
                channelLocations: Int = 0
            ) {
                self.sampleRateCode = sampleRateCode
                self.bitstreamID = bitstreamID
                self.isAudioServiceMixed = isAudioServiceMixed
                self.bitstreamMode = bitstreamMode
                self.audioCodingMode = audioCodingMode
                self.hasLowFrequencyEffects = hasLowFrequencyEffects
                self.dependentSubstreamCount = dependentSubstreamCount
                self.channelLocations = channelLocations
            }
        }

        /// In kilobits per second.
        public let dataRate = FormatAttribute<Int>("dataRate")
        public let substreams = FormatAttribute<[Substream]>("substreams")
        /// The complexity of the joint object coding of Dolby Atmos; set only when the stream has it.
        public let jointObjectCodingComplexity = FormatAttribute<Int>("jointObjectCodingComplexity")

        public init() {}
    }

    /// AC-4: the `dac4` box.
    struct AC4: FormatAttributeScope {
        /// The box as it is, from its size field, which decoders take as their configuration.
        public let decoderSpecificInfo = FormatAttribute<Data>("decoderSpecificInfo")

        public init() {}
    }

    /// Dolby TrueHD: what a `dmlp` box carries.
    struct TrueHD: FormatAttributeScope {
        public let formatInfo = FormatAttribute<UInt32>("formatInfo")
        public let peakDataRate = FormatAttribute<Int>("peakDataRate")

        public init() {}
    }
}

// MARK: - Opus, Vorbis, FLAC, ALAC

public extension AudioCodec {
    /// Opus: what the identification header of RFC 7845 carries.
    struct Opus: FormatAttributeScope {
        public let channelCount = FormatAttribute<Int>("channelCount")
        /// Samples at 48000 Hz to drop from the start of the decoder's output.
        public let preSkip = FormatAttribute<Int>("preSkip")
        /// The rate of the audio before it was encoded.
        public let inputSampleRate = FormatAttribute<Int>("inputSampleRate")
        /// In units of 1/256 decibels.
        public let outputGain = FormatAttribute<Int>("outputGain")
        public let channelMappingFamily = FormatAttribute<Int>("channelMappingFamily")
        public let streamCount = FormatAttribute<Int>("streamCount")
        public let coupledStreamCount = FormatAttribute<Int>("coupledStreamCount")
        public let channelMapping = FormatAttribute<[UInt8]>("channelMapping")
        /// Samples at 48000 Hz to decode before a position seeked to.
        public let seekPreRoll = FormatAttribute<Int>("seekPreRoll")

        public init() {}
    }

    struct Vorbis: FormatAttributeScope {
        public let identificationHeader = FormatAttribute<Data>("identificationHeader")
        public let setupHeader = FormatAttribute<Data>("setupHeader")

        public init() {}
    }

    /// FLAC: the fields of the STREAMINFO metadata block, and the blocks after it.
    struct FLAC: FormatAttributeScope {
        public struct MetadataBlock: Hashable, Sendable {
            public var type: Int
            public var data: Data

            public init(type: Int, data: Data) {
                self.type = type
                self.data = data
            }
        }

        public let minimumBlockSize = FormatAttribute<Int>("minimumBlockSize")
        public let maximumBlockSize = FormatAttribute<Int>("maximumBlockSize")
        public let minimumFrameSize = FormatAttribute<Int>("minimumFrameSize")
        public let maximumFrameSize = FormatAttribute<Int>("maximumFrameSize")
        public let sampleRate = FormatAttribute<Int>("sampleRate")
        public let channelCount = FormatAttribute<Int>("channelCount")
        public let bitsPerSample = FormatAttribute<Int>("bitsPerSample")
        public let totalSamples = FormatAttribute<Int>("totalSamples")
        /// The MD5 of the decoded audio.
        public let signature = FormatAttribute<Data>("signature")
        public let additionalMetadataBlocks = DefaultedFormatAttribute<[MetadataBlock]>(
            "additionalMetadataBlocks",
            default: []
        )

        public init() {}
    }

    /// Apple Lossless: what an `ALACSpecificConfig` carries.
    struct ALAC: FormatAttributeScope {
        public let frameLength = FormatAttribute<Int>("frameLength")
        public let compatibleVersion = FormatAttribute<Int>("compatibleVersion")
        public let bitDepth = FormatAttribute<Int>("bitDepth")
        public let historyMultiplier = FormatAttribute<Int>("historyMultiplier")
        public let initialHistory = FormatAttribute<Int>("initialHistory")
        public let riceParameterLimit = FormatAttribute<Int>("riceParameterLimit")
        public let channelCount = FormatAttribute<Int>("channelCount")
        public let maximumRun = FormatAttribute<Int>("maximumRun")
        public let maximumFrameBytes = FormatAttribute<Int>("maximumFrameBytes")
        public let averageBitrate = FormatAttribute<Int>("averageBitrate")
        public let sampleRate = FormatAttribute<Int>("sampleRate")

        public init() {}
    }
}

// MARK: - Other codecs

public extension AudioCodec {
    struct PCM: FormatAttributeScope {
        public enum SampleFormat: Hashable, Sendable {
            case signedInteger
            case unsignedInteger
            case float
        }

        public let bitDepth = FormatAttribute<Int>("bitDepth")
        public let sampleFormat = DefaultedFormatAttribute<SampleFormat>("sampleFormat", default: .signedInteger)
        public let isBigEndian = DefaultedFormatAttribute<Bool>("isBigEndian", default: false)

        public init() {}
    }

    /// DTS: the `ddts` or `udts` box. Which of its coding systems the stream uses is in the MIME type.
    struct DTS: FormatAttributeScope {
        /// The box as it is, from its size field, which decoders take as their configuration.
        public let decoderSpecificInfo = FormatAttribute<Data>("decoderSpecificInfo")

        public init() {}
    }

    /// MPEG-H 3D audio: what an `mhaC` box carries. Whether samples are MHAS packets that carry their own
    /// configuration, as an `mhm1` track's are, is in the MIME type.
    struct MPEGH: FormatAttributeScope {
        public let profileLevelIndication = FormatAttribute<Int>("profileLevelIndication")
        public let referenceChannelLayout = FormatAttribute<Int>("referenceChannelLayout")
        /// The `mpegh3daConfig`.
        public let configuration = FormatAttribute<Data>("configuration")

        public init() {}
    }

    /// AMR: what a `damr` box carries.
    struct AMR: FormatAttributeScope {
        /// The vendor of the encoder.
        public let vendor = FormatAttribute<FourCharacterCode>("vendor")
        public let decoderVersion = FormatAttribute<Int>("decoderVersion")
        public let modeSet = FormatAttribute<Int>("modeSet")
        public let modeChangePeriod = FormatAttribute<Int>("modeChangePeriod")
        public let framesPerSample = FormatAttribute<Int>("framesPerSample")

        public init() {}
    }

    /// IAMF: the `iacb` box.
    struct IAMF: FormatAttributeScope {
        /// The box as it is, from its size field, which decoders take as their configuration.
        public let decoderSpecificInfo = FormatAttribute<Data>("decoderSpecificInfo")

        public init() {}
    }

    /// Apple Positional Audio Codec: what a `dapa` box carries.
    struct APAC: FormatAttributeScope {
        /// The version of the bitstream the configuration is written for.
        public let bitstreamVersion = FormatAttribute<Int>("bitstreamVersion")
        public let profile = FormatAttribute<Int>("profile")
        public let level = FormatAttribute<Int>("level")
        /// The box as it is, from its size field, which decoders take as their configuration.
        public let decoderSpecificInfo = FormatAttribute<Data>("decoderSpecificInfo")

        public init() {}
    }
}
