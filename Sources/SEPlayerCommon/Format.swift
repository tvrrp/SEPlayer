//
//  Format.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.06.2025.
//

import CoreMedia
import Foundation
import QuartzCore

public extension Format {
    protocol InitializationData: Hashable, Sendable {
        func getInitializationData() throws -> [BlockBufferReader]
        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription
    }

    // TODO: make real sendable
    struct ByteBufferInitializationData: InitializationData, @unchecked Sendable {
        public let byteBuffer: [BlockBufferReader]

        public init(byteBuffer: [BlockBufferReader]) {
            self.byteBuffer = byteBuffer
        }

        public func getInitializationData() throws -> [BlockBufferReader] {
            byteBuffer
        }
    }
}

public extension Format.InitializationData {
    func getInitializationData() throws -> [BlockBufferReader] {
        throw UnsupportedOperationError()
    }

    func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription {
        throw UnsupportedOperationError()
    }
}

public final class Format: Sendable {
    public let id: String?
    public let label: String?
    public let labels: [String]
    public let language: String?
    public let selectionFlags: SelectionFlags
    public let roleFlags: RoleFlags
    public let averageBitrate: Int
    public let peakBitrate: Int
    public let bitrate: Int
    public let codecs: String?

    /// Container specific.
    public let containerMimeType: MimeTypes?

    // Sample specific.
    public let sampleMimeType: MimeTypes?
    public let maxInputSize: Int
    public let maxNumReorderSamples: Int
    public let initializationData: (any InitializationData)?
    public let subsampleOffset: CMTime
    public let hasPrerollSamples: Bool

    // Text specific.

    /// The replacement behavior that should be followed when handling consecutive samples in a text track
    /// of `MimeTypes.applicationSEPlayerCues`.
    public let cueReplacementBehavior: CueReplacementBehavior
    /// The channel of closed captions: 1 to 4 for CEA-608 CC1 to CC4, the service number for CEA-708, or
    /// `Format.noValue`.
    public let accessibilityChannel: Int

    // Video specific.
    public let width: Int
    public let height: Int
    public let frameRate: Float
    /// The dynamic range of the video, as HLS `VIDEO-RANGE` declares it.
    public let videoRange: VideoRange
    public let rotationDegrees: CGFloat
    public let transform3D: CATransform3D
    public let pixelWidthHeightRatio: Float
    public let maxSubLayers: Int

    // Audio specific.
    public let channelCount: Int
    public let sampleRate: Int
    // let pcmEncoding: Int
    public let encoderDelay: Int
    public let encoderPadding: Int

    fileprivate init(builder: Builder) {
        id = builder.id
        label = builder.label
        labels = builder.labels
        language = Util.normalizeLanguageCode(builder.language)
        selectionFlags = builder.selectionFlags
        roleFlags = builder.roleFlags
        averageBitrate = builder.averageBitrate
        peakBitrate = builder.peakBitrate
        bitrate = peakBitrate != Format.noValue ? peakBitrate : averageBitrate
        codecs = builder.codecs
        // Container specific.
        containerMimeType = builder.containerMimeType
        // Sample specific.
        sampleMimeType = builder.sampleMimeType
        maxInputSize = builder.maxInputSize
        maxNumReorderSamples = builder.maxNumReorderSamples
        initializationData = builder.initializationData
        subsampleOffset = builder.subsampleOffset
        hasPrerollSamples = builder.hasPrerollSamples
        // Text specific.
        cueReplacementBehavior = builder.cueReplacementBehavior
        accessibilityChannel = builder.accessibilityChannel
        // Video specific.
        width = builder.width
        height = builder.height
        frameRate = builder.frameRate
        videoRange = builder.videoRange
        rotationDegrees = builder.rotationDegrees
        transform3D = builder.transform3D
        pixelWidthHeightRatio = builder.pixelWidthHeightRatio
        maxSubLayers = builder.maxSubLayers
        // Audio specific.
        channelCount = builder.channelCount
        sampleRate = builder.sampleRate
        encoderDelay = builder.encoderDelay
        encoderPadding = builder.encoderPadding
    }

    public func buildUpon() -> Builder { Builder(format: self) }

    public func buildFormatDescription() throws -> CMFormatDescription {
        guard let initializationData else {
            throw Error.initializationDataIsEmpty
        }

        return try initializationData.buildCMFormatDescription(using: self)
    }

    public func getInitializationData() throws -> [BlockBufferReader] {
        guard let initializationData else {
            throw Error.initializationDataIsEmpty
        }

        return try initializationData.getInitializationData()
    }
}

public extension Format {
    static let noValue: Int = -1
    static let offsetSampleRelative = CMTime.positiveInfinity

    enum Error: Swift.Error {
        case initializationDataIsEmpty
    }

    /// The replacement behaviors for consecutive samples in an `MimeTypes.applicationSEPlayerCues` track.
    @frozen
    enum CueReplacementBehavior: Hashable, Sendable {
        /// Subtitle cues from each sample are shown until they are explicitly cleared (e.g. an empty
        /// sample) or their duration elapses.
        ///
        /// Cues may be shown at the same time as cues from previous or later samples, if they overlap.
        case merge
        /// Subtitle cues from each sample are shown until the next sample, or their duration elapses,
        /// whichever is sooner.
        ///
        /// If a sample has no explicit duration, its cues are shown until the next sample.
        case replace
    }
}

extension Format: Hashable {
    public static func == (lhs: Format, rhs: Format) -> Bool {
        guard lhs !== rhs else { return true }

        return lhs.id == rhs.id &&
            lhs.label == rhs.label &&
            lhs.labels == rhs.labels &&
            lhs.language == rhs.language &&
            lhs.selectionFlags == rhs.selectionFlags &&
            lhs.averageBitrate == rhs.averageBitrate &&
            lhs.peakBitrate == rhs.peakBitrate &&
            lhs.codecs == rhs.codecs &&
            lhs.containerMimeType == rhs.containerMimeType &&
            lhs.sampleMimeType == rhs.sampleMimeType &&
            lhs.maxInputSize == rhs.maxInputSize &&
            lhs.maxNumReorderSamples == rhs.maxNumReorderSamples &&
            lhs.subsampleOffset == rhs.subsampleOffset &&
            lhs.hasPrerollSamples == rhs.hasPrerollSamples &&
            lhs.cueReplacementBehavior == rhs.cueReplacementBehavior &&
            lhs.accessibilityChannel == rhs.accessibilityChannel &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.frameRate == rhs.frameRate &&
            lhs.videoRange == rhs.videoRange &&
            lhs.rotationDegrees == rhs.rotationDegrees &&
            lhs.pixelWidthHeightRatio == rhs.pixelWidthHeightRatio &&
            lhs.maxSubLayers == rhs.maxSubLayers &&
            lhs.channelCount == rhs.channelCount &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.encoderDelay == rhs.encoderDelay &&
            lhs.encoderPadding == rhs.encoderPadding &&
            // Formats that differ only in their codec configuration, as variants of an HLS stream of one size do,
            // are different: samples of one can't be decoded with the other.
            initializationDataEquals(lhs.initializationData, rhs.initializationData)
    }

    private static func initializationDataEquals(
        _ lhs: (any InitializationData)?,
        _ rhs: (any InitializationData)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): AnyHashable(lhs) == AnyHashable(rhs)
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(label)
        hasher.combine(labels)
        hasher.combine(language)
        hasher.combine(selectionFlags)
        hasher.combine(averageBitrate)
        hasher.combine(peakBitrate)
        hasher.combine(codecs)
        hasher.combine(containerMimeType)
        hasher.combine(sampleMimeType)
        hasher.combine(maxInputSize)
        hasher.combine(maxNumReorderSamples)
        hasher.combine(subsampleOffset)
        hasher.combine(hasPrerollSamples)
        hasher.combine(cueReplacementBehavior)
        hasher.combine(accessibilityChannel)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(frameRate)
        hasher.combine(videoRange)
        hasher.combine(rotationDegrees)
        hasher.combine(pixelWidthHeightRatio)
        hasher.combine(maxSubLayers)
        hasher.combine(channelCount)
        hasher.combine(sampleRate)
        hasher.combine(encoderDelay)
        hasher.combine(encoderPadding)
        hasher.combine(initializationData.map { AnyHashable($0) })
    }
}

extension Format: CustomStringConvertible, CustomDebugStringConvertible {
    /// One line with what tells formats apart: ids, types, codecs, bitrate, and the size or channels.
    public var description: String {
        var parts = [String]()
        if let id { parts.append("id=\(id)") }
        if let containerMimeType { parts.append("container=\(containerMimeType.rawValue)") }
        if let sampleMimeType { parts.append("mime=\(sampleMimeType.rawValue)") }
        if let codecs { parts.append("codecs=\(codecs)") }
        if bitrate != Format.noValue { parts.append("bitrate=\(bitrate)") }
        if width != Format.noValue, height != Format.noValue { parts.append("res=\(width)x\(height)") }
        if frameRate > 0 { parts.append("fps=\(frameRate)") }
        if videoRange != .unknown { parts.append("range=\(videoRange)") }
        if channelCount != Format.noValue { parts.append("channels=\(channelCount)") }
        if sampleRate != Format.noValue { parts.append("sample_rate=\(sampleRate)") }
        if accessibilityChannel != Format.noValue { parts.append("channel=\(accessibilityChannel)") }
        if let language { parts.append("language=\(language)") }
        if let label { parts.append("label=\(label)") }
        if !selectionFlags.isEmpty { parts.append("selection=\(selectionFlags)") }
        if !roleFlags.isEmpty { parts.append("role=\(roleFlags)") }
        return "Format(\(parts.joined(separator: ", ")))"
    }

    /// Every field, one per line.
    public var debugDescription: String {
        let fields: [(String, Any?)] = [
            ("id", id),
            ("label", label),
            ("labels", labels),
            ("language", language),
            ("selectionFlags", selectionFlags),
            ("roleFlags", roleFlags),
            ("averageBitrate", averageBitrate),
            ("peakBitrate", peakBitrate),
            ("bitrate", bitrate),
            ("codecs", codecs),
            ("containerMimeType", containerMimeType?.rawValue),
            ("sampleMimeType", sampleMimeType?.rawValue),
            ("maxInputSize", maxInputSize),
            ("maxNumReorderSamples", maxNumReorderSamples),
            ("initializationData", initializationData.map { "\(type(of: $0))" }),
            ("subsampleOffset", subsampleOffset.seconds),
            ("hasPrerollSamples", hasPrerollSamples),
            ("cueReplacementBehavior", cueReplacementBehavior),
            ("accessibilityChannel", accessibilityChannel),
            ("width", width),
            ("height", height),
            ("frameRate", frameRate),
            ("videoRange", videoRange),
            ("rotationDegrees", rotationDegrees),
            ("pixelWidthHeightRatio", pixelWidthHeightRatio),
            ("maxSubLayers", maxSubLayers),
            ("channelCount", channelCount),
            ("sampleRate", sampleRate),
            ("encoderDelay", encoderDelay),
            ("encoderPadding", encoderPadding),
        ]
        let lines = fields.map { name, value in
            "  \(name): \(value.map { "\($0)" } ?? "nil")"
        }
        return "Format(\n\(lines.joined(separator: "\n"))\n)"
    }
}

extension Format {
    public final class Builder {
        fileprivate var id: String?
        fileprivate var label: String?
        fileprivate var labels: [String]
        fileprivate var language: String?
        fileprivate var selectionFlags = SelectionFlags()
        fileprivate var roleFlags = RoleFlags()
        fileprivate var averageBitrate: Int
        fileprivate var peakBitrate: Int
        fileprivate var codecs: String?

        /// Container specific.
        fileprivate var containerMimeType: MimeTypes?

        // Sample specific.
        fileprivate var sampleMimeType: MimeTypes?
        fileprivate var maxInputSize: Int
        fileprivate var maxNumReorderSamples: Int
        fileprivate var initializationData: (any Format.InitializationData)?
        fileprivate var subsampleOffset: CMTime
        fileprivate var hasPrerollSamples: Bool

        // Text specific.
        fileprivate var cueReplacementBehavior: CueReplacementBehavior
        fileprivate var accessibilityChannel: Int

        // Video specific.
        fileprivate var width: Int
        fileprivate var height: Int
        fileprivate var frameRate: Float
        fileprivate var videoRange: VideoRange
        fileprivate var rotationDegrees: CGFloat
        fileprivate var transform3D: CATransform3D
        fileprivate var pixelWidthHeightRatio: Float
        fileprivate var maxSubLayers: Int

        // Audio specific.
        fileprivate var channelCount: Int
        fileprivate var sampleRate: Int
        // private(set) var pcmEncoding: Int
        fileprivate var encoderDelay: Int
        fileprivate var encoderPadding: Int

        public init() {
            labels = []
            averageBitrate = Format.noValue
            peakBitrate = Format.noValue
            // Sample specific.
            maxInputSize = Format.noValue
            maxNumReorderSamples = Format.noValue
            subsampleOffset = Format.offsetSampleRelative
            hasPrerollSamples = false
            // Text specific.
            cueReplacementBehavior = .merge
            accessibilityChannel = Format.noValue
            // Video specific.
            width = Format.noValue
            height = Format.noValue
            frameRate = Float(Format.noValue)
            videoRange = .unknown
            rotationDegrees = .zero
            transform3D = CATransform3DIdentity
            pixelWidthHeightRatio = 1.0
            maxSubLayers = Format.noValue

            // Audio specific.
            channelCount = Format.noValue
            sampleRate = Format.noValue
            encoderDelay = .zero
            encoderPadding = .zero
        }

        fileprivate init(format: Format) {
            id = format.id
            label = format.label
            labels = format.labels
            language = format.language
            selectionFlags = format.selectionFlags
            roleFlags = format.roleFlags
            averageBitrate = format.averageBitrate
            peakBitrate = format.peakBitrate
            codecs = format.codecs
            // Container specific.
            containerMimeType = format.containerMimeType
            // Sample specific.
            sampleMimeType = format.sampleMimeType
            maxInputSize = format.maxInputSize
            maxNumReorderSamples = format.maxNumReorderSamples
            initializationData = format.initializationData
            subsampleOffset = format.subsampleOffset
            hasPrerollSamples = format.hasPrerollSamples
            // Text specific.
            cueReplacementBehavior = format.cueReplacementBehavior
            accessibilityChannel = format.accessibilityChannel
            // Video specific.
            width = format.width
            height = format.height
            frameRate = format.frameRate
            videoRange = format.videoRange
            rotationDegrees = format.rotationDegrees
            transform3D = format.transform3D
            pixelWidthHeightRatio = format.pixelWidthHeightRatio
            maxSubLayers = format.maxSubLayers
            // Audio specific.
            channelCount = format.channelCount
            sampleRate = format.sampleRate
            encoderDelay = format.encoderDelay
            encoderPadding = format.encoderPadding
        }

        @discardableResult
        public func setId(_ id: String) -> Builder {
            self.id = id
            return self
        }

        @discardableResult
        public func setId(_ id: Int) -> Builder {
            self.id = String(id)
            return self
        }

        @discardableResult
        public func setLabel(_ label: String?) -> Builder {
            self.label = label
            return self
        }

        @discardableResult
        public func setLabels(_ labels: [String]) -> Builder {
            self.labels = labels
            return self
        }

        @discardableResult
        public func setLanguage(_ language: String?) -> Builder {
            self.language = language
            return self
        }

        @discardableResult
        public func setSelectionFlags(_ selectionFlags: SelectionFlags) -> Builder {
            self.selectionFlags = selectionFlags
            return self
        }

        @discardableResult
        public func setRoleFlags(_ roleFlags: RoleFlags) -> Builder {
            self.roleFlags = roleFlags
            return self
        }

        @discardableResult
        public func setAverageBitrate(_ averageBitrate: Int) -> Builder {
            self.averageBitrate = averageBitrate
            return self
        }

        @discardableResult
        public func setPeakBitrate(_ peakBitrate: Int) -> Builder {
            self.peakBitrate = peakBitrate
            return self
        }

        @discardableResult
        public func setCodecs(_ codecs: String?) -> Builder {
            self.codecs = codecs
            return self
        }

        /// Container specific
        @discardableResult
        public func setContainerMimeType(_ containerMimeType: MimeTypes?) -> Builder {
            self.containerMimeType = containerMimeType
            return self
        }

        /// Sample specific
        @discardableResult
        public func setSampleMimeType(_ sampleMimeType: MimeTypes?) -> Builder {
            self.sampleMimeType = sampleMimeType
            return self
        }

        @discardableResult
        public func setMaxInputSize(_ maxInputSize: Int) -> Builder {
            self.maxInputSize = maxInputSize
            return self
        }

        @discardableResult
        public func setMaxNumReorderSamples(_ maxNumReorderSamples: Int) -> Builder {
            self.maxNumReorderSamples = maxNumReorderSamples
            return self
        }

        @discardableResult
        public func setInitializationData(_ initializationData: (any InitializationData)?) -> Builder {
            self.initializationData = initializationData
            return self
        }

        @discardableResult
        public func setSubsampleOffset(_ subsampleOffset: CMTime) -> Builder {
            self.subsampleOffset = subsampleOffset
            return self
        }

        @discardableResult
        public func setHasPrerollSamples(_ hasPrerollSamples: Bool) -> Builder {
            self.hasPrerollSamples = hasPrerollSamples
            return self
        }

        /// Text specific
        @discardableResult
        public func setCueReplacementBehavior(_ cueReplacementBehavior: CueReplacementBehavior) -> Builder {
            self.cueReplacementBehavior = cueReplacementBehavior
            return self
        }

        @discardableResult
        public func setAccessibilityChannel(_ accessibilityChannel: Int) -> Builder {
            self.accessibilityChannel = accessibilityChannel
            return self
        }

        /// Video specific
        @discardableResult
        public func setSize(width: Int, height: Int) -> Builder {
            self.width = width
            self.height = height
            return self
        }

        @discardableResult
        public func setVideoRange(_ videoRange: VideoRange) -> Builder {
            self.videoRange = videoRange
            return self
        }

        @discardableResult
        public func setFrameRate(_ frameRate: Float) -> Builder {
            self.frameRate = frameRate
            return self
        }

        @discardableResult
        public func setRotationDegrees(_ rotationDegrees: CGFloat) -> Builder {
            self.rotationDegrees = rotationDegrees
            return self
        }

        @discardableResult
        public func setTransform3D(_ transform3D: CATransform3D) -> Builder {
            self.transform3D = transform3D
            return self
        }

        @discardableResult
        public func setPixelWidthHeightRatio(_ ratio: Float) -> Builder {
            self.pixelWidthHeightRatio = ratio
            return self
        }

        @discardableResult
        public func setMaxSubLayers(_ maxSubLayers: Int) -> Builder {
            self.maxSubLayers = maxSubLayers
            return self
        }

        /// Audio specific
        @discardableResult
        public func setChannelCount(_ channelCount: Int) -> Builder {
            self.channelCount = channelCount
            return self
        }

        @discardableResult
        public func setSampleRate(_ sampleRate: Int) -> Builder {
            self.sampleRate = sampleRate
            return self
        }

        @discardableResult
        public func setEncoderDelay(_ encoderDelay: Int) -> Builder {
            self.encoderDelay = encoderDelay
            return self
        }

        @discardableResult
        public func setEncoderPadding(_ encoderPadding: Int) -> Builder {
            self.encoderPadding = encoderPadding
            return self
        }

        public func build() -> Format { Format(builder: self) }
    }
}

public extension Format {
    /// The dynamic range of a video.
    enum VideoRange: Int, Hashable, Sendable, Comparable {
        case unknown = 0
        case sdr = 1
        /// Hybrid log-gamma: HDR that SDR displays can show.
        case hlg = 2
        /// Perceptual quantizer: HDR10, HDR10+ and Dolby Vision.
        case pq = 3

        /// The range of an HLS `VIDEO-RANGE` attribute.
        public init(hlsAttribute value: String) {
            switch value.uppercased() {
            case "SDR": self = .sdr
            case "HLG": self = .hlg
            case "PQ": self = .pq
            default: self = .unknown
            }
        }

        public static func < (lhs: VideoRange, rhs: VideoRange) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
