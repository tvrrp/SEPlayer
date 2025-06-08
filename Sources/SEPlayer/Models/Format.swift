//
//  Format.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.06.2025.
//

import Foundation

struct Format: Hashable {
    let id: String?
    let label: String?
    let labels: [String]
    let language: String?
    let averageBitrate: Int
    let peakBitrate: Int
    let codecs: String?
//    let customData: Any?

    // Container specific.
    let containerMimeType: String?

    // Sample specific.
    let sampleMimeType: String?
    let maxInputSize: Int
    let maxNumReorderSamples: Int
    let initializationData: Data?
    let subsampleOffsetUs: Int64
    let hasPrerollSamples: Bool

    // Video specific.
    let size: CGSize
    let frameRate: Float
    let rotationDegrees: Int
    let pixelWidthHeightRatio: Float
    let projectionData: Data?
    // let stereoMode: StereoMode
    // let colorInfo: ColorInfo
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
//        customData = builder.customData
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
        size = builder.size
        frameRate = builder.frameRate
        rotationDegrees = builder.rotationDegrees
        pixelWidthHeightRatio = builder.pixelWidthHeightRatio
        projectionData = builder.projectionData
        maxSubLayers = builder.maxSubLayers
        // Audio specific.
        channelCount = builder.channelCount
        sampleRate = builder.sampleRate
        encoderDelay = builder.encoderDelay
        encoderPadding = builder.encoderPadding
    }

    func buildUpon() -> Builder { Builder(format: self) }
}

extension Format {
    static let noValue: Int = -1
    static let offsetSampleRelative = Int64.max
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
//        private var customData: Any?

        // Container specific.
        fileprivate var containerMimeType: String?

        // Sample specific.
        fileprivate var sampleMimeType: String?
        fileprivate var maxInputSize: Int
        fileprivate var maxNumReorderSamples: Int
        fileprivate var initializationData: Data?
        fileprivate var subsampleOffsetUs: Int64
        fileprivate var hasPrerollSamples: Bool

        // Video specific.
        fileprivate var size: CGSize
        fileprivate var frameRate: Float
        fileprivate var rotationDegrees: Int
        fileprivate var pixelWidthHeightRatio: Float
        fileprivate var projectionData: Data?
        // private(set) var stereoMode: StereoMode
        // private(set) var colorInfo: ColorInfo
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
            size = CGSize(width: Format.noValue, height: Format.noValue)
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
//            customData = format.customData
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
            size = format.size
            frameRate = format.frameRate
            rotationDegrees = format.rotationDegrees
            pixelWidthHeightRatio = format.pixelWidthHeightRatio
            projectionData = format.projectionData
            maxSubLayers = format.maxSubLayers
            // Audio specific.
            channelCount = format.channelCount
            sampleRate = format.sampleRate
            encoderDelay = format.encoderDelay
            encoderPadding = format.encoderPadding
        }

        @discardableResult
        func setId(_ id: String?) -> Builder {
            var value = self
            value.id = id
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

//        @discardableResult
//        func setCustomData(_ customData: Any?) -> Builder {
//            var value = self
//            value.customData = customData
//            return value
//        }

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
        func setInitializationData(_ initializationData: Data?) -> Builder {
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
        func setSize(_ size: CGSize) -> Builder {
            var value = self
            value.size = size
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
        func setProjectionData(_ projectionData: Data?) -> Builder {
            var value = self
            value.projectionData = projectionData
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
