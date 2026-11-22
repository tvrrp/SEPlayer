//
//  SampleProperties.swift
//  SEPlayer
//

import CoreMedia
import Foundation

/// What is known about one sample of a track besides its bytes: its times, where its bytes are, what it is among the
/// samples of its stream, and the attributes few samples have.
///
///     var sample = SampleProperties(timingInfo: timingInfo, dataRange: 0 ..< size)
///     sample.isKeyframe = true
///     sample.attributes.trimAtStart = encoderDelay
public struct SampleProperties: Sendable {
    public var timingInfo: CMSampleTimingInfo
    /// Where the bytes of the sample are. For a ``TrackOutput``, in the bytes written to it, counted back from their
    /// end: `0 ..< size` for the sample written last.
    public var dataRange: Range<Int>
    /// Everything the `is…` properties tell, to set or to pass on at once.
    public var flags: Flags

    /// The attributes few samples have. A sample without any keeps nothing for them.
    public var attributes: SampleAttributes {
        get { attributeStorage?.attributes ?? SampleAttributes() }
        set { attributeStorage = newValue.isEmpty ? nil : AttributeStorage(newValue) }
    }

    /// Whether anything of the sample plays. A sample trimmed whole only primes the decoder for those after it.
    public var hasOutput: Bool {
        guard let attributes = attributeStorage?.attributes, timingInfo.duration.isNumeric else {
            return true
        }
        return attributes.trimAtStart + attributes.trimAtEnd < timingInfo.duration
    }

    /// Whether decoding can start at the sample.
    public var isKeyframe: Bool {
        get { flags.contains(.keyframe) }
        set { set(.keyframe, newValue) }
    }

    /// Whether the sample marks the end of its stream.
    public var isEndOfStream: Bool {
        get { flags.contains(.endOfStream) }
        set { set(.endOfStream, newValue) }
    }

    /// Whether no sample needs this one to be decoded, so that it can be dropped.
    public var isDroppable: Bool {
        get { flags.contains(.notDependedOn) }
        set { set(.notDependedOn, newValue) }
    }

    /// Whether the sample is the first of its stream.
    public var isFirstSample: Bool {
        get { flags.contains(.firstSample) }
        set { set(.firstSample, newValue) }
    }

    /// Whether the sample is the last of its stream.
    public var isLastSample: Bool {
        get { flags.contains(.lastSample) }
        set { set(.lastSample, newValue) }
    }

    /// Whether decoding can start at the sample, though the samples that follow it and are shown before it can't be
    /// decoded then. Such a sample isn't a keyframe.
    public var isPartialSync: Bool {
        get { flags.contains(.partialSync) }
        set { set(.partialSync, newValue) }
    }

    /// Whether the sample needs no other sample to be decoded.
    public var isIndependent: Bool {
        get { flags.contains(.independent) }
        set { set(.independent, newValue) }
    }

    /// Whether the sample repeats what other samples code, for a decoder that lost them.
    public var hasRedundantCoding: Bool {
        get { flags.contains(.hasRedundantCoding) }
        set { set(.hasRedundantCoding, newValue) }
    }

    /// Whether the sample is decoded for the samples after it, and isn't shown or played itself.
    public var isDecodeOnly: Bool {
        get { flags.contains(.decodeOnly) }
        set { set(.decodeOnly, newValue) }
    }

    /// Whether the sample is shown as soon as it is decoded, whatever its time.
    public var displaysImmediately: Bool {
        get { flags.contains(.displayImmediately) }
        set { set(.displayImmediately, newValue) }
    }

    /// Whether samples after this one in decoding order may be shown before it.
    public var allowsEarlierDisplayTimes: Bool {
        get { flags.contains(.allowsEarlierDisplayTimes) }
        set { set(.allowsEarlierDisplayTimes, newValue) }
    }

    /// Whether the decoder starts anew before it decodes the sample.
    public var resetsDecoder: Bool {
        get { flags.contains(.resetsDecoder) }
        set { set(.resetsDecoder, newValue) }
    }

    /// Whether the decoder gives out everything it holds once it has decoded the sample.
    public var drainsDecoder: Bool {
        get { flags.contains(.drainsDecoder) }
        set { set(.drainsDecoder, newValue) }
    }

    private var attributeStorage: AttributeStorage?

    public init(timingInfo: CMSampleTimingInfo, dataRange: Range<Int> = 0 ..< 0, flags: Flags = []) {
        self.timingInfo = timingInfo
        self.dataRange = dataRange
        self.flags = flags
    }

    /// Trims the sample to what of it is within `range`, a range of the times its presentation time is in. A sample
    /// outside the range is trimmed whole.
    public mutating func trim(to range: CMTimeRange) {
        let start = timingInfo.presentationTimeStamp
        let duration = timingInfo.duration
        guard start.isNumeric, duration.isNumeric, duration > .zero else {
            return
        }

        var attributes = attributes
        if range.start.isNumeric {
            attributes.trimAtStart = min(max(attributes.trimAtStart, range.start - start), duration)
        }
        if range.end.isNumeric {
            let trimAtEnd = max(attributes.trimAtEnd, start + duration - range.end)
            attributes.trimAtEnd = min(trimAtEnd, duration - attributes.trimAtStart)
        }
        self.attributes = attributes
    }

    private mutating func set(_ flag: Flags, _ isSet: Bool) {
        if isSet {
            flags.insert(flag)
        } else {
            flags.remove(flag)
        }
    }
}

public extension SampleProperties {
    struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let keyframe = Flags(rawValue: 1 << 0)
        public static let endOfStream = Flags(rawValue: 1 << 1)
        public static let notDependedOn = Flags(rawValue: 1 << 2)
        public static let firstSample = Flags(rawValue: 1 << 3)
        public static let lastSample = Flags(rawValue: 1 << 4)
        public static let partialSync = Flags(rawValue: 1 << 5)
        public static let independent = Flags(rawValue: 1 << 6)
        public static let hasRedundantCoding = Flags(rawValue: 1 << 7)
        public static let decodeOnly = Flags(rawValue: 1 << 8)
        public static let displayImmediately = Flags(rawValue: 1 << 9)
        public static let allowsEarlierDisplayTimes = Flags(rawValue: 1 << 10)
        public static let resetsDecoder = Flags(rawValue: 1 << 11)
        public static let drainsDecoder = Flags(rawValue: 1 << 12)
    }

    /// The attributes of a sample that has some, shared by its copies.
    private final class AttributeStorage: Sendable {
        let attributes: SampleAttributes

        init(_ attributes: SampleAttributes) {
            self.attributes = attributes
        }
    }
}

/// The attributes of samples that few of them have.
public struct SampleAttributes: Hashable, Sendable {
    /// How much of the sample isn't played at its start, such as the delay of an audio encoder or what an edit cuts.
    /// The sample is decoded whole.
    public var trimAtStart = CMTime.zero
    /// How much of the sample isn't played at its end, such as the padding of an audio encoder.
    public var trimAtEnd = CMTime.zero
    /// The temporal layer of a picture: a decoder that skips the layers above one still decodes those up to it.
    public var temporalLevel: Int?
    /// The type of the NAL units of a sync sample of HEVC, which tells what kind of random access point it is.
    public var syncSampleNALUnitType: Int?
    /// Whether a decoder can switch up to the temporal layer of the picture at it.
    public var temporalSubLayerAccess: TemporalSubLayerAccess?
    /// For an audio packet a decoder can start at: how many packets it decodes before its output is right.
    public var audioDecoderRefreshCount: Int?
    /// The dynamic metadata of HDR10+ for the picture, as its ITU-T T.35 user data carries it.
    public var hdr10PlusMetadata: Data?

    public var isEmpty: Bool { self == SampleAttributes() }

    public init() {}
}

/// How a decoder can switch up to a temporal layer at a picture.
public enum TemporalSubLayerAccess: Hashable, Sendable {
    /// To the layer of the picture and, from there, to any layer above it.
    case full
    /// To the layer of the picture only, one layer at a time.
    case stepwise
}
