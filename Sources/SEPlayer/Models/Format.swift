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
        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription
    }
}

public final class Format: Sendable {
    let id: String?
    let label: String?
    let labels: [String]
    let language: String?
    let averageBitrate: Int
    let peakBitrate: Int
    let codecs: String?

    // Container specific.
    let containerMimeType: MimeTypes?

    // Sample specific.
    let sampleMimeType: MimeTypes?
    let maxInputSize: Int
    let maxNumReorderSamples: Int
    let initializationData: (any InitializationData)?
    let subsampleOffsetUs: Int64
    let hasPrerollSamples: Bool

    // Video specific.
    let width: Int
    let height: Int
    let frameRate: Float
    let rotationDegrees: CGFloat
    let transform3D: CATransform3D
    let pixelWidthHeightRatio: Float
    let maxSubLayers: Int

    // Audio specific.
    let channelCount: Int
    let sampleRate: Int
    // let pcmEncoding: Int
    let encoderDelay: Int
    let encoderPadding: Int

    fileprivate init(builder: Builder) {
        id = builder.id
        label = builder.label
        labels = builder.labels
        language = builder.language
        averageBitrate = builder.averageBitrate
        peakBitrate = builder.peakBitrate
        codecs = builder.codecs
        // Container specific.
        containerMimeType = builder.containerMimeType
        // Sample specific.
        sampleMimeType = builder.sampleMimeType
        maxInputSize = builder.maxInputSize
        maxNumReorderSamples = builder.maxNumReorderSamples
        initializationData = builder.initializationData
        subsampleOffsetUs = builder.subsampleOffsetUs
        hasPrerollSamples = builder.hasPrerollSamples
        // Video specific.
        width = builder.width
        height = builder.height
        frameRate = builder.frameRate
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

    func buildUpon() -> Builder { Builder(format: self) }

    func buildFormatDescription() throws -> CMFormatDescription {
        guard let initializationData else {
            throw Error.initializationDataIsEmpty
        }

        return try initializationData.buildCMFormatDescription(using: self)
    }
}

public extension Format {
    static let noValue: Int = -1
    static let offsetSampleRelative = Int64.max

    enum Error: Swift.Error {
        case initializationDataIsEmpty
    }
}

extension Format: Hashable {
    public static func == (lhs: Format, rhs: Format) -> Bool {
        return lhs.id == rhs.id &&
            lhs.label == rhs.label &&
            lhs.labels == rhs.labels &&
            lhs.language == rhs.language &&
            lhs.averageBitrate == rhs.averageBitrate &&
            lhs.peakBitrate == rhs.peakBitrate &&
            lhs.codecs == rhs.codecs &&
            lhs.containerMimeType == rhs.containerMimeType &&
            lhs.sampleMimeType == rhs.sampleMimeType &&
            lhs.maxInputSize == rhs.maxInputSize &&
            lhs.maxNumReorderSamples == rhs.maxNumReorderSamples &&
            lhs.subsampleOffsetUs == rhs.subsampleOffsetUs &&
            lhs.hasPrerollSamples == rhs.hasPrerollSamples &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.frameRate == rhs.frameRate &&
            lhs.rotationDegrees == rhs.rotationDegrees &&
            lhs.pixelWidthHeightRatio == rhs.pixelWidthHeightRatio &&
            lhs.maxSubLayers == rhs.maxSubLayers &&
            lhs.channelCount == rhs.channelCount &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.encoderDelay == rhs.encoderDelay &&
            lhs.encoderPadding == rhs.encoderPadding
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(label)
        hasher.combine(labels)
        hasher.combine(language)
        hasher.combine(averageBitrate)
        hasher.combine(peakBitrate)
        hasher.combine(codecs)
        hasher.combine(containerMimeType)
        hasher.combine(sampleMimeType)
        hasher.combine(maxInputSize)
        hasher.combine(maxNumReorderSamples)
        hasher.combine(subsampleOffsetUs)
        hasher.combine(hasPrerollSamples)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(frameRate)
        hasher.combine(rotationDegrees)
        hasher.combine(pixelWidthHeightRatio)
        hasher.combine(maxSubLayers)
        hasher.combine(channelCount)
        hasher.combine(sampleRate)
        hasher.combine(encoderDelay)
        hasher.combine(encoderPadding)
    }
}

extension Format {
    final class Builder {
        fileprivate var id: String?
        fileprivate var label: String?
        fileprivate var labels: [String]
        fileprivate var language: String?
        fileprivate var averageBitrate: Int
        fileprivate var peakBitrate: Int
        fileprivate var codecs: String?

        // Container specific.
        fileprivate var containerMimeType: MimeTypes?

        // Sample specific.
        fileprivate var sampleMimeType: MimeTypes?
        fileprivate var maxInputSize: Int
        fileprivate var maxNumReorderSamples: Int
        fileprivate var initializationData: (any Format.InitializationData)?
        fileprivate var subsampleOffsetUs: Int64
        fileprivate var hasPrerollSamples: Bool

        // Video specific.
        fileprivate var width: Int
        fileprivate var height: Int
        fileprivate var frameRate: Float
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

        init() {
            labels = []
            averageBitrate = Format.noValue
            peakBitrate = Format.noValue
            // Sample specific.
            maxInputSize = Format.noValue
            maxNumReorderSamples = Format.noValue
            subsampleOffsetUs = Format.offsetSampleRelative
            hasPrerollSamples = false
            // Video specific.
            width = Format.noValue
            height = Format.noValue
            frameRate = Float(Format.noValue)
            rotationDegrees = .zero
            transform3D = CATransform3DIdentity
            pixelWidthHeightRatio = 1.0
            maxSubLayers = Format.noValue;

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
            subsampleOffsetUs = format.subsampleOffsetUs
            hasPrerollSamples = format.hasPrerollSamples
            // Video specific.
            width = format.width
            height = format.height
            frameRate = format.frameRate
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
        func setId(_ id: Int) -> Builder {
            self.id = String(id)
            return self
        }

        @discardableResult
        func setLabel(_ label: String?) -> Builder {
            self.label = label
            return self
        }

        @discardableResult
        func setLabels(_ labels: [String]) -> Builder {
            self.labels = labels
            return self
        }

        @discardableResult
        func setLanguage(_ language: String?) -> Builder {
            self.language = language
            return self
        }

        @discardableResult
        func setAverageBitrate(_ averageBitrate: Int) -> Builder {
            self.averageBitrate = averageBitrate
            return self
        }

        @discardableResult
        func setPeakBitrate(_ peakBitrate: Int) -> Builder {
            self.peakBitrate = peakBitrate
            return self
        }

        @discardableResult
        func setCodecs(_ codecs: String?) -> Builder {
            self.codecs = codecs
            return self
        }

        // Container specific
        @discardableResult
        func setContainerMimeType(_ containerMimeType: MimeTypes?) -> Builder {
            self.containerMimeType = containerMimeType
            return self
        }

        // Sample specific
        @discardableResult
        func setSampleMimeType(_ sampleMimeType: MimeTypes?) -> Builder {
            self.sampleMimeType = sampleMimeType
            return self
        }

        @discardableResult
        func setMaxInputSize(_ maxInputSize: Int) -> Builder {
            self.maxInputSize = maxInputSize
            return self
        }

        @discardableResult
        func setMaxNumReorderSamples(_ maxNumReorderSamples: Int) -> Builder {
            self.maxNumReorderSamples = maxNumReorderSamples
            return self
        }

        @discardableResult
        func setInitializationData(_ initializationData: (any InitializationData)?) -> Builder {
            self.initializationData = initializationData
            return self
        }

        @discardableResult
        func setSubsampleOffsetUs(_ subsampleOffsetUs: Int64) -> Builder {
            self.subsampleOffsetUs = subsampleOffsetUs
            return self
        }

        @discardableResult
        func setHasPrerollSamples(_ hasPrerollSamples: Bool) -> Builder {
            self.hasPrerollSamples = hasPrerollSamples
            return self
        }

        // Video specific
        @discardableResult
        func setSize(width: Int, height: Int) -> Builder {
            self.width = width
            self.height = height
            return self
        }

        @discardableResult
        func setFrameRate(_ frameRate: Float) -> Builder {
            self.frameRate = frameRate
            return self
        }

        @discardableResult
        func setRotationDegrees(_ rotationDegrees: CGFloat) -> Builder {
            self.rotationDegrees = rotationDegrees
            return self
        }

        @discardableResult
        func setTransform3D(_ transform3D: CATransform3D) -> Builder {
            self.transform3D = transform3D
            return self
        }

        @discardableResult
        func setPixelWidthHeightRatio(_ ratio: Float) -> Builder {
            self.pixelWidthHeightRatio = ratio
            return self
        }

        @discardableResult
        func setMaxSubLayers(_ maxSubLayers: Int) -> Builder {
            self.maxSubLayers = maxSubLayers
            return self
        }

        // Audio specific
        @discardableResult
        func setChannelCount(_ channelCount: Int) -> Builder {
            self.channelCount = channelCount
            return self
        }

        @discardableResult
        func setSampleRate(_ sampleRate: Int) -> Builder {
            self.sampleRate = sampleRate
            return self
        }

        @discardableResult
        func setEncoderDelay(_ encoderDelay: Int) -> Builder {
            self.encoderDelay = encoderDelay
            return self
        }

        @discardableResult
        func setEncoderPadding(_ encoderPadding: Int) -> Builder {
            self.encoderPadding = encoderPadding
            return self
        }

        func build() -> Format { Format(builder: self) }
    }
}
