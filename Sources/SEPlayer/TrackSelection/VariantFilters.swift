//
//  VariantFilters.swift
//  SEPlayer
//

import AVFoundation
import SEPlayerCommon
import VideoToolbox

/// The codec and dynamic range rules that leave out variants of a stream before one is picked by bandwidth.
///
/// In the order they apply:
/// 1. Video ranges the display can't show go, except HLG, which SDR displays show.
/// 2. If a variant can be decoded in hardware, the variants that can't go.
/// 3. In Low Power Mode, HDR and software-decoded variants go, unless no other is left.
/// 4. The best video range for the display is kept: the highest it can show. Within it, Dolby Vision is kept over other
///    codecs if the display supports it; other codecs are equal.
/// 5. Among SDR variants, the best codec (AV1 > HEVC > VP9 > AVC) replaces the others in the range of resolutions it
///    covers. A low resolution only another codec has stays.
enum VariantFilters {
    /// What the rules depend on.
    struct Environment {
        /// The best dynamic range the display shows.
        var displayVideoRange: VideoRange
        var supportsDolbyVision: Bool
        var isLowPowerModeEnabled: Bool
        var isHardwareDecodeSupported: (VideoFormat) -> Bool

        static func current() -> Environment {
            let isHDR = AVPlayer.eligibleForHDRPlayback
            return Environment(
                displayVideoRange: isHDR ? .pq : .sdr,
                supportsDolbyVision: isHDR,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                isHardwareDecodeSupported: { $0.isHardwareDecodeSupported }
            )
        }
    }

    /// The best video format of a variant's codecs.
    enum VideoFormat: Int, Comparable {
        case none = 0
        case other = 1
        case avc = 2
        case vp9 = 3
        case hevc = 4
        case av1 = 5
        case dolbyVisionHEVC = 7
        case dolbyVisionAV1 = 8

        init(codecs: String?) {
            let codecs = Codecs.split(codecs).map { $0.lowercased() }
            func has(_ prefixes: String...) -> Bool {
                codecs.contains { codec in prefixes.contains { codec.hasPrefix($0) } }
            }
            if has("dav1") {
                self = .dolbyVisionAV1
            } else if has("dvh1", "dvhe") {
                self = .dolbyVisionHEVC
            } else if has("av01") {
                self = .av1
            } else if has("hvc1", "hev1") {
                self = .hevc
            } else if has("vp09") {
                self = .vp9
            } else if has("avc1", "avc3") {
                self = .avc
            } else if codecs.contains(where: { Codecs.mediaMimeType(forCodec: $0)?.trackType == .video }) {
                self = .other
            } else {
                self = .none
            }
        }

        var isDolbyVision: Bool { self == .dolbyVisionHEVC || self == .dolbyVisionAV1 }

        /// Formats are equal for the preference, except Dolby Vision, which ranks above the others.
        var preferenceRank: Int { isDolbyVision ? rawValue : VideoFormat.av1.rawValue + 1 }

        fileprivate var isHardwareDecodeSupported: Bool {
            #if targetEnvironment(simulator)
            // The simulator decodes everything in software, and reports no hardware decoders.
            true
            #else
            switch self {
            case .none,
                 .other,
                 .avc: true
            case .hevc,
                 .dolbyVisionHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            case .vp9: VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
            case .av1,
                 .dolbyVisionAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
            }
            #endif
        }

        static func < (lhs: VideoFormat, rhs: VideoFormat) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The indices of `formats` the rules keep. Never empty for a non-empty `formats`.
    static func allowedIndices(of formats: [AnyFormat], environment: Environment) -> [Int] {
        let variants = formats.enumerated().map {
            Variant(index: $0.offset, format: $0.element, supportsDolbyVision: environment.supportsDolbyVision)
        }
        var kept = variants

        kept = kept.filter { supportsVideoRange($0, environment: environment) }
        kept = preferHardwareDecode(kept, environment: environment)
        if environment.isLowPowerModeEnabled {
            let avoided = kept.filter { !$0.hasVideo || ($0.isHardwareDecoded(environment) && $0.range <= .sdr) }
            if !avoided.isEmpty { kept = avoided }
        }
        kept = preferVideoRangeAndFormat(kept, environment: environment)
        kept = preferBestSDRFormat(kept)

        // The rules without a fallback can leave nothing: then they say nothing.
        return kept.isEmpty ? Array(formats.indices) : kept.map(\.index)
    }

    // MARK: - Rules

    private struct Variant {
        let index: Int
        let format: AnyFormat
        let videoFormat: VideoFormat

        init(index: Int, format: AnyFormat, supportsDolbyVision: Bool) {
            self.index = index
            self.format = format
            let codecs = format.codecs ?? format.sampleMimeType.flatMap(Self.codec(of:))
            // A Dolby Vision layer on another codec is played where the display supports it; elsewhere the base is.
            if supportsDolbyVision, let supplementalCodecs = format.supplementalCodecs {
                videoFormat = max(VideoFormat(codecs: codecs), VideoFormat(codecs: supplementalCodecs))
            } else {
                videoFormat = VideoFormat(codecs: codecs)
            }
        }

        var hasVideo: Bool { videoFormat != .none }
        var range: VideoRange { format.video?.videoRange ?? .sdr }

        func isHardwareDecoded(_ environment: Environment) -> Bool {
            environment.isHardwareDecodeSupported(videoFormat)
        }

        private static func codec(of mimeType: MimeTypes) -> String? {
            switch mimeType {
            case .videoH264: "avc1"
            case .videoH265: "hvc1"
            case .videoDolbyVision: "dvh1"
            case .videoAV1: "av01"
            case .videoVP9: "vp09"
            default: nil
            }
        }
    }

    /// Whether the display shows the video range of the variant.
    private static func supportsVideoRange(_ variant: Variant, environment: Environment) -> Bool {
        guard variant.hasVideo else { return true }
        let display = environment.displayVideoRange
        return variant.range <= display || (variant.range == .hlg && display == .sdr)
    }

    /// If some variant is decoded in hardware, those that aren't go.
    private static func preferHardwareDecode(_ variants: [Variant], environment: Environment) -> [Variant] {
        guard variants.contains(where: { $0.hasVideo && $0.isHardwareDecoded(environment) }) else {
            return variants
        }
        return variants.filter { !$0.hasVideo || $0.isHardwareDecoded(environment) }
    }

    /// The variants with the best video range for the display and, within it, the best format.
    private static func preferVideoRangeAndFormat(_ variants: [Variant], environment: Environment) -> [Variant] {
        let preferredRange = environment.displayVideoRange
        // A PQ display without Dolby Vision prefers formats up to AV1; others any format.
        let preferredRank = environment.displayVideoRange == .pq && !environment.supportsDolbyVision
            ? VideoFormat.av1.rawValue + 1
            : Int.max

        func rangeScore(_ range: VideoRange) -> (Bool, Int) {
            // Ranges the display shows come first, the highest first; then the others, the nearest first.
            range <= preferredRange ? (true, range.rawValue) : (false, -range.rawValue)
        }
        func formatScore(_ format: VideoFormat) -> (Bool, Int) {
            format.preferenceRank <= preferredRank ? (true, format.preferenceRank) : (false, -format.preferenceRank)
        }
        func isBetter(_ lhs: (Bool, Int), _ rhs: (Bool, Int)) -> Bool {
            lhs.0 != rhs.0 ? lhs.0 : lhs.1 > rhs.1
        }

        let video = variants.filter(\.hasVideo)
        // A preference for one format: variants of exactly the preferred range and format win outright.
        if preferredRank != Int.max {
            let exact = video.filter { $0.range == preferredRange && $0.videoFormat == .av1 }
            if !exact.isEmpty {
                return variants.filter { !$0.hasVideo || ($0.range == preferredRange && $0.videoFormat == .av1) }
            }
        }
        guard let best = video.max(by: { lhs, rhs in
            let lhsRange = rangeScore(lhs.range), rhsRange = rangeScore(rhs.range)
            if lhsRange != rhsRange { return isBetter(rhsRange, lhsRange) }
            return isBetter(formatScore(rhs.videoFormat), formatScore(lhs.videoFormat))
        }) else {
            return variants
        }
        return variants.filter {
            !$0.hasVideo
                || (rangeScore($0.range) == rangeScore(best.range)
                    && formatScore($0.videoFormat) == formatScore(best.videoFormat))
        }
    }

    /// Within the resolution buckets the best SDR format
    /// covers, the other formats go.
    private static func preferBestSDRFormat(_ variants: [Variant]) -> [Variant] {
        let sdr = variants.filter { $0.hasVideo && $0.range == .sdr }
        guard let best = sdr.map(\.videoFormat).max() else { return variants }
        let buckets = sdr.filter { $0.videoFormat == best }.compactMap { resolutionBucket(of: $0.format) }
        guard let lowest = buckets.min(), let highest = buckets.max() else {
            return variants
        }

        return variants.filter { variant in
            guard variant.hasVideo, variant.range == .sdr, variant.videoFormat != best,
                  let bucket = resolutionBucket(of: variant.format) else {
                return true
            }
            return bucket < lowest || bucket > highest
        }
    }

    /// Upper heights of the resolution buckets.
    private static let resolutionBucketLimits = [240, 360, 480, 900, 1440, 2700, 3780]

    private static func resolutionBucket(of format: AnyFormat) -> Int? {
        guard let height = format.video?.size?.height, height > 0 else {
            return nil
        }
        return resolutionBucketLimits.firstIndex { height <= $0 } ?? resolutionBucketLimits.count
    }
}
