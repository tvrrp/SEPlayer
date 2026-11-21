//
//  VideoAttributeValues.swift
//  SEPlayer
//

import Foundation

/// The fields of a visual sample entry before its boxes, QuickTime's image description alike.
public struct VisualSampleEntryFields: Hashable, Sendable {
    public var version: Int16
    public var revisionLevel: Int16
    /// The vendor of the compressor, or a code of 0.
    public var vendor: FourCharacterCode
    public var temporalQuality: Int32
    public var spatialQuality: Int32
    /// The name of the compressor, or the format in quotes when the entry has none.
    public var compressorName: String
    /// The bits of a pixel, 24 for colour without alpha; 0 when the entry doesn't tell.
    public var depth: Int

    public init(
        version: Int16,
        revisionLevel: Int16,
        vendor: FourCharacterCode,
        temporalQuality: Int32,
        spatialQuality: Int32,
        compressorName: String,
        depth: Int
    ) {
        self.version = version
        self.revisionLevel = revisionLevel
        self.vendor = vendor
        self.temporalQuality = temporalQuality
        self.spatialQuality = spatialQuality
        self.compressorName = compressorName
        self.depth = depth
    }
}

/// The spacing of pixels, horizontal over vertical, as a `pasp` box or a VUI gives it.
public struct PixelAspectRatio: Hashable, Sendable {
    public var horizontalSpacing: Int
    public var verticalSpacing: Int

    public var ratio: Float { Float(horizontalSpacing) / Float(verticalSpacing) }

    public init(horizontalSpacing: Int, verticalSpacing: Int) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }
}

/// A fraction, as boxes write sizes and offsets that aren't whole.
public struct Rational: Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public var value: Double { Double(numerator) / Double(denominator) }

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// The part of the picture to show: its size, and the offset of its centre from that of the picture.
public struct CleanAperture: Hashable, Sendable {
    public var width: Rational
    public var height: Rational
    public var horizontalOffset: Rational
    public var verticalOffset: Rational

    public init(width: Rational, height: Rational, horizontalOffset: Rational, verticalOffset: Rational) {
        self.width = width
        self.height = height
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
    }
}

/// The order of the two fields of interlaced pictures.
public enum FieldOrder: Hashable, Sendable, CaseIterable {
    case temporalTopFirst
    case temporalBottomFirst
    case spatialFirstLineEarly
    case spatialFirstLineLate
}

/// Where chroma samples are, as H.264 Table E-1 numbers them, and the siting of DV 4:2:0.
public enum ChromaLocation: Int, Hashable, Sendable, CaseIterable {
    case left = 0
    case center
    case topLeft
    case top
    case bottomLeft
    case bottom
    case dv420 = 255
}

/// The viewing environment the video was graded for, as H.265 D.2.39 writes it.
public struct AmbientViewingEnvironment: Hashable, Sendable {
    /// In units of 0.0001 lux.
    public var illuminance: UInt32
    /// The chromaticity of the light, in units of 0.00002.
    public var lightX: UInt16
    public var lightY: UInt16

    public init(illuminance: UInt32, lightX: UInt16, lightY: UInt16) {
        self.illuminance = illuminance
        self.lightX = lightX
        self.lightY = lightY
    }
}

/// The colour volume of the content, as H.265 D.2.40 writes it.
public struct ContentColorVolume: Hashable, Sendable {
    /// Whether it cancels the volume of earlier pictures, and tells nothing else.
    public var isCanceled: Bool
    public var persists: Bool
    /// The chromaticities of the primaries, x then y for each, in units of 0.00002.
    public var primaries: [Int32]?
    /// In units of 0.0000001 candelas per square metre.
    public var minimumLuminance: UInt32?
    public var maximumLuminance: UInt32?
    public var averageLuminance: UInt32?

    public init(
        isCanceled: Bool = false,
        persists: Bool = false,
        primaries: [Int32]? = nil,
        minimumLuminance: UInt32? = nil,
        maximumLuminance: UInt32? = nil,
        averageLuminance: UInt32? = nil
    ) {
        self.isCanceled = isCanceled
        self.persists = persists
        self.primaries = primaries
        self.minimumLuminance = minimumLuminance
        self.maximumLuminance = maximumLuminance
        self.averageLuminance = averageLuminance
    }
}

/// How the colour of pictures with alpha relates to it.
public enum AlphaChannelMode: Hashable, Sendable, CaseIterable {
    case straight
    case premultiplied
}

/// The eyes the views of stereo video are for.
public struct StereoViews: OptionSet, Hashable, Sendable {
    public static let left = StereoViews(rawValue: 1 << 0)
    public static let right = StereoViews(rawValue: 1 << 1)
    public static let additionalViews = StereoViews(rawValue: 1 << 2)
    public static let eyesReversed = StereoViews(rawValue: 1 << 3)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// The eye whose view shows when stereo video plays as one view.
public enum HeroEye: Hashable, Sendable, CaseIterable {
    case unspecified
    case left
    case right
    case reserved
}

/// How the pictures map to the field of view.
public enum VideoProjection: Hashable, Sendable, CaseIterable {
    case rectilinear
    case equirectangular
    case halfEquirectangular
    case appleImmersiveVideo
    case parametricImmersive
}

/// How the views of stereo video share a picture.
public enum ViewPacking: Hashable, Sendable, CaseIterable {
    case unspecified
    case sideBySide
    case overUnder
}
