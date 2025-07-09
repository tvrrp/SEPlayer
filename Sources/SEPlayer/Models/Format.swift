//
//  Format.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.06.2025.
//

import Foundation
import CoreMedia

extension Format {
    protocol InitializationData: Hashable {
        func buildCMFormatDescription(using format: Format) throws -> CMFormatDescription
    }
}

struct Format {
    let id: String?
    let label: String?
    let labels: [String]
    let language: String?
    let averageBitrate: Int
    let peakBitrate: Int
    let codecs: String?

    // Container specific.
    let containerMimeType: String?

    // Sample specific.
    let sampleMimeType: String?
    let maxInputSize: Int
    let maxNumReorderSamples: Int
    let initializationData: InitializationData?
    let subsampleOffsetUs: Int64
    let hasPrerollSamples: Bool

    // Video specific.
    let width: Int
    let height: Int
    let frameRate: Float
    let rotationDegrees: Int
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
        pixelWidthHeightRatio = builder.pixelWidthHeightRatio
        maxSubLayers = builder.maxSubLayers
        // Audio specific.
        channelCount = builder.channelCount
        sampleRate = builder.sampleRate
        encoderDelay = builder.encoderDelay
        encoderPadding = builder.encoderPadding
    }

    func buildUpon() -> Builder { Builder(format: self) }

    func buildFormatDescription() throws -> CMFormatDescription? {
        try initializationData?.buildCMFormatDescription(using: self)
    }
}

extension Format {
    static let noValue: Int = -1
    static let offsetSampleRelative = Int64.max
}

extension Format: Hashable {
    static func == (lhs: Format, rhs: Format) -> Bool {
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

    func hash(into hasher: inout Hasher) {
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
    struct Builder {
        fileprivate var id: String?
        fileprivate var label: String?
        fileprivate var labels: [String]
        fileprivate var language: String?
        fileprivate var averageBitrate: Int
        fileprivate var peakBitrate: Int
        fileprivate var codecs: String?

        // Container specific.
        fileprivate var containerMimeType: String?

        // Sample specific.
        fileprivate var sampleMimeType: String?
        fileprivate var maxInputSize: Int
        fileprivate var maxNumReorderSamples: Int
        fileprivate var initializationData: InitializationData?
        fileprivate var subsampleOffsetUs: Int64
        fileprivate var hasPrerollSamples: Bool

        // Video specific.
        fileprivate var width: Int
        fileprivate var height: Int
        fileprivate var frameRate: Float
        fileprivate var rotationDegrees: Int
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
            var value = self
            value.id = String(id)
            return value
        }

        @discardableResult
        func setLabel(_ label: String?) -> Builder {
            var value = self
            value.label = label
            return value
        }

        @discardableResult
        func setLabels(_ labels: [String]) -> Builder {
            var value = self
            value.labels = labels
            return value
        }

        @discardableResult
        func setLanguage(_ language: String?) -> Builder {
            var value = self
            value.language = language
            return value
        }

        @discardableResult
        func setAverageBitrate(_ averageBitrate: Int) -> Builder {
            var value = self
            value.averageBitrate = averageBitrate
            return value
        }

        @discardableResult
        func setPeakBitrate(_ peakBitrate: Int) -> Builder {
            var value = self
            value.peakBitrate = peakBitrate
            return value
        }

        @discardableResult
        func setCodecs(_ codecs: String?) -> Builder {
            var value = self
            value.codecs = codecs
            return value
        }

        // Container specific
        @discardableResult
        func setContainerMimeType(_ containerMimeType: String?) -> Builder {
            var value = self
            value.containerMimeType = containerMimeType
            return value
        }

        // Sample specific
        @discardableResult
        func setSampleMimeType(_ sampleMimeType: String?) -> Builder {
            var value = self
            value.sampleMimeType = sampleMimeType
            return value
        }

        @discardableResult
        func setMaxInputSize(_ maxInputSize: Int) -> Builder {
            var value = self
            value.maxInputSize = maxInputSize
            return value
        }

        @discardableResult
        func setMaxNumReorderSamples(_ maxNumReorderSamples: Int) -> Builder {
            var value = self
            value.maxNumReorderSamples = maxNumReorderSamples
            return value
        }

        @discardableResult
        func setInitializationData(_ initializationData: InitializationData?) -> Builder {
            var value = self
            value.initializationData = initializationData
            return value
        }

        @discardableResult
        func setSubsampleOffsetUs(_ subsampleOffsetUs: Int64) -> Builder {
            var value = self
            value.subsampleOffsetUs = subsampleOffsetUs
            return value
        }

        @discardableResult
        func setHasPrerollSamples(_ hasPrerollSamples: Bool) -> Builder {
            var value = self
            value.hasPrerollSamples = hasPrerollSamples
            return value
        }

        // Video specific
        @discardableResult
        func setSize(width: Int, height: Int) -> Builder {
            var value = self
            value.width = width
            value.height = height
            return value
        }

        @discardableResult
        func setFrameRate(_ frameRate: Float) -> Builder {
            var value = self
            value.frameRate = frameRate
            return value
        }

        @discardableResult
        func setRotationDegrees(_ rotationDegrees: Int) -> Builder {
            var value = self
            value.rotationDegrees = rotationDegrees
            return value
        }

        @discardableResult
        func setPixelWidthHeightRatio(_ ratio: Float) -> Builder {
            var value = self
            value.pixelWidthHeightRatio = ratio
            return value
        }

        @discardableResult
        func setMaxSubLayers(_ maxSubLayers: Int) -> Builder {
            var value = self
            value.maxSubLayers = maxSubLayers
            return value
        }

        // Audio specific
        @discardableResult
        func setChannelCount(_ channelCount: Int) -> Builder {
            var value = self
            value.channelCount = channelCount
            return value
        }

        @discardableResult
        func setSampleRate(_ sampleRate: Int) -> Builder {
            var value = self
            value.sampleRate = sampleRate
            return value
        }

        @discardableResult
        func setEncoderDelay(_ encoderDelay: Int) -> Builder {
            var value = self
            value.encoderDelay = encoderDelay
            return value
        }

        @discardableResult
        func setEncoderPadding(_ encoderPadding: Int) -> Builder {
            var value = self
            value.encoderPadding = encoderPadding
            return value
        }

        func build() -> Format { Format(builder: self) }
    }
}
