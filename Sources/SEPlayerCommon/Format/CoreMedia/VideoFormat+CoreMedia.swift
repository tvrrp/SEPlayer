//
//  VideoFormat+CoreMedia.swift
//  SEPlayer
//

import CoreMedia
import CoreVideo
import Foundation

public extension Format where Scope == FormatAttributes.Video {
    /// A format description of the samples: the codec type, the size, and the extensions the attributes give.
    func formatDescription() throws -> CMFormatDescription {
        let size = try self.size.checkNotNil(FormatConversionError.missingAttribute("size"))
        let codecType = try self.codecType?.rawValue ?? Self.codecType(of: self.codec)
        return try CMFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: codecType),
            width: size.width,
            height: size.height,
            extensions: coreMediaExtensions
        )
    }

    /// The attributes of what a format description holds: the codec type, the size and the extensions. What the
    /// codec's configuration tells is left to its readers.
    init(copying description: CMFormatDescription) throws {
        guard description.mediaType == .video else {
            throw FormatConversionError.mediaTypeMismatch
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] ?? [:]
        self.init()
        self.codecType = FourCharacterCode(description.mediaSubType.rawValue)
        self.size = VideoSize(width: Int(description.dimensions.width), height: Int(description.dimensions.height))
        readCommonExtensions(extensions)
        readVideoExtensions(extensions)
    }
}

// MARK: - Extensions

private extension Format where Scope == FormatAttributes.Video {
    var coreMediaExtensions: [CFString: Any] {
        var extensions = commonExtensions { Self.describedBoxes.contains($0.type) }
        if let fields = self.sampleEntryFields {
            extensions[kCMFormatDescriptionExtension_Version] = fields.version
            extensions[kCMFormatDescriptionExtension_RevisionLevel] = fields.revisionLevel
            extensions[kCMFormatDescriptionExtension_TemporalQuality] = fields.temporalQuality
            extensions[kCMFormatDescriptionExtension_SpatialQuality] = fields.spatialQuality
            extensions[kCMFormatDescriptionExtension_FormatName] = fields.compressorName
            if fields.vendor.rawValue != 0 {
                extensions[kCMFormatDescriptionExtension_Vendor] = fields.vendor.description
            }
            if fields.depth != 0 {
                extensions[kCMFormatDescriptionExtension_Depth] = fields.depth
            }
        }
        extensions[VideoKey.conformsToMPEG2VideoProfile] = self.mpeg2Profile.map { Int32(bitPattern: $0.rawValue) }
        addColor(to: &extensions)
        addPicture(to: &extensions)
        addHighDynamicRange(to: &extensions)
        addExtendedUsage(to: &extensions)
        return extensions
    }

    func addColor(to extensions: inout [CFString: Any]) {
        extensions[kCMFormatDescriptionExtension_ColorPrimaries] = self.colorPrimaries.flatMap {
            CVColorPrimariesGetStringForIntegerCodePoint(Int32($0.rawValue))?.takeUnretainedValue()
        }
        // A power law of a gamma level has no code point.
        if self.transferFunction == .unspecified, self.gammaLevel != nil {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCVImageBufferTransferFunction_UseGamma
        } else {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = self.transferFunction.flatMap(Self.name(of:))
        }
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = self.matrixCoefficients.flatMap {
            CVYCbCrMatrixGetStringForIntegerCodePoint(Int32($0.rawValue))?.takeUnretainedValue()
        }
        extensions[VideoKey.alternativeTransferCharacteristics] = self.alternativeTransferFunction.flatMap(Self.name(of:))
        extensions[kCMFormatDescriptionExtension_GammaLevel] = self.gammaLevel
        extensions[kCMFormatDescriptionExtension_ICCProfile] = self.iccProfile
        extensions[VideoKey.logTransferFunction] = self.logTransferFunction
        extensions[kCMFormatDescriptionExtension_FullRangeVideo] = self.isFullRange
        extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = self.chromaLocationTopField.map(Self.name(of:))
        extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField] = self.chromaLocationBottomField.map(Self.name(of:))
        extensions[VideoKey.bitsPerComponent] = self.bitsPerComponent
    }

    func addPicture(to extensions: inout [CFString: Any]) {
        if let ratio = self.pixelAspectRatio {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: ratio.horizontalSpacing,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: ratio.verticalSpacing,
            ]
        } else if let ratio = self.size?.pixelWidthHeightRatio, ratio > 0, ratio != 1 {
            let (horizontal, vertical) = Self.fraction(of: ratio)
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: horizontal,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: vertical,
            ]
        }
        if let aperture = self.cleanAperture {
            extensions[kCMFormatDescriptionExtension_CleanAperture] = Self.dictionary(of: aperture)
        }
        extensions[kCMFormatDescriptionExtension_FieldCount] = self.fieldCount
        extensions[kCMFormatDescriptionExtension_FieldDetail] = self.fieldOrder.map(Self.name(of:))
        extensions[kCMFormatDescriptionExtension_BytesPerRow] = self.bytesPerRow
        extensions[VideoKey.alphaChannelMode] = self.alphaChannelMode.map(Self.name(of:))
        extensions[VideoKey.containsAlphaChannel] = self.containsAlphaChannel
    }

    func addHighDynamicRange(to extensions: inout [CFString: Any]) {
        extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = self.masteringDisplay?.bytes
        extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = self.contentLightLevel?.bytes
        extensions[VideoKey.ambientViewingEnvironment] = self.ambientViewingEnvironment?.bytes
        extensions[VideoKey.contentColorVolume] = self.contentColorVolume?.bytes
    }

    func addExtendedUsage(to extensions: inout [CFString: Any]) {
        extensions[VideoKey.horizontalFieldOfView] = self.horizontalFieldOfView
        for (view, key) in Self.stereoViewKeys where self.stereoViews?.contains(view) == true {
            extensions[key] = true
        }
        extensions[VideoKey.heroEye] = self.heroEye.map(Self.name(of:))
        extensions[VideoKey.stereoCameraBaseline] = self.stereoCameraBaseline
        extensions[VideoKey.horizontalDisparityAdjustment] = self.horizontalDisparityAdjustment
        extensions[VideoKey.transportIdentifier] = self.transportIdentifier
        extensions[VideoKey.projectionKind] = self.projection.map(Self.name(of:))
        extensions[VideoKey.viewPackingKind] = self.viewPacking.map(Self.name(of:))
        extensions[VideoKey.requiredButUnrecognizedFormatAtoms] = self.unrecognizedRequiredBoxPaths?.map { path in
            path.map { Int32(bitPattern: $0.rawValue) }
        }
    }

    /// The clean aperture as descriptions keep it: its values, with the fractions that aren't whole.
    static func dictionary(of aperture: CleanAperture) -> [CFString: Any] {
        var dictionary: [CFString: Any] = [:]
        let values: [(Rational, CFString, CFString)] = [
            (aperture.width, kCMFormatDescriptionKey_CleanApertureWidth, kCMFormatDescriptionKey_CleanApertureWidthRational),
            (aperture.height, kCMFormatDescriptionKey_CleanApertureHeight, kCMFormatDescriptionKey_CleanApertureHeightRational),
            (
                aperture.horizontalOffset,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational
            ),
            (
                aperture.verticalOffset,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset,
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational
            ),
        ]
        for (value, key, rationalKey) in values {
            dictionary[key] = value.value
            if value.denominator != 1 {
                dictionary[rationalKey] = [Int32(truncatingIfNeeded: value.numerator), Int32(truncatingIfNeeded: value.denominator)]
            }
        }
        return dictionary
    }
}

// MARK: - Reading

private extension Format where Scope == FormatAttributes.Video {
    mutating func readVideoExtensions(_ extensions: [CFString: Any]) {
        func number(_ key: CFString) -> Int? { (extensions[key] as? NSNumber)?.intValue }
        func string(_ key: CFString) -> String? { extensions[key] as? String }

        if let version = number(kCMFormatDescriptionExtension_Version) {
            self.sampleEntryFields = VisualSampleEntryFields(
                version: Int16(truncatingIfNeeded: version),
                revisionLevel: Int16(truncatingIfNeeded: number(kCMFormatDescriptionExtension_RevisionLevel) ?? 0),
                vendor: string(kCMFormatDescriptionExtension_Vendor).map { FourCharacterCode($0) } ?? FourCharacterCode(0),
                temporalQuality: Int32(truncatingIfNeeded: number(kCMFormatDescriptionExtension_TemporalQuality) ?? 0),
                spatialQuality: Int32(truncatingIfNeeded: number(kCMFormatDescriptionExtension_SpatialQuality) ?? 0),
                compressorName: string(kCMFormatDescriptionExtension_FormatName) ?? "",
                depth: number(kCMFormatDescriptionExtension_Depth) ?? 0
            )
        }
        self.mpeg2Profile = number(VideoKey.conformsToMPEG2VideoProfile)
            .map { FourCharacterCode(UInt32(truncatingIfNeeded: $0)) }

        if let name = string(kCMFormatDescriptionExtension_ColorPrimaries) {
            self.colorPrimaries = ColorPrimaries(rawValue: Int(CVColorPrimariesGetIntegerCodePointForString(name as CFString)))
        }
        if let name = string(kCMFormatDescriptionExtension_TransferFunction) {
            self.transferFunction = name == kCVImageBufferTransferFunction_UseGamma as String
                ? .unspecified
                : TransferFunction(rawValue: Int(CVTransferFunctionGetIntegerCodePointForString(name as CFString)))
        }
        if let name = string(kCMFormatDescriptionExtension_YCbCrMatrix) {
            self.matrixCoefficients = MatrixCoefficients(rawValue: Int(CVYCbCrMatrixGetIntegerCodePointForString(name as CFString)))
        }
        if let name = string(VideoKey.alternativeTransferCharacteristics) {
            self.alternativeTransferFunction = TransferFunction(
                rawValue: Int(CVTransferFunctionGetIntegerCodePointForString(name as CFString))
            )
        }
        self.gammaLevel = (extensions[kCMFormatDescriptionExtension_GammaLevel] as? NSNumber)?.doubleValue
        self.iccProfile = extensions[kCMFormatDescriptionExtension_ICCProfile] as? Data
        self.logTransferFunction = string(VideoKey.logTransferFunction)
        self.isFullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool
        self.chromaLocationTopField = Self.value(named: string(kCMFormatDescriptionExtension_ChromaLocationTopField))
        self.chromaLocationBottomField = Self.value(named: string(kCMFormatDescriptionExtension_ChromaLocationBottomField))
        self.bitsPerComponent = number(VideoKey.bitsPerComponent)

        if let ratio = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? [CFString: Any],
           let horizontal = (ratio[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.intValue,
           let vertical = (ratio[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.intValue {
            let pixelAspectRatio = PixelAspectRatio(horizontalSpacing: horizontal, verticalSpacing: vertical)
            self.pixelAspectRatio = pixelAspectRatio
            if horizontal > 0, vertical > 0, let size = self.size {
                self.size = VideoSize(width: size.width, height: size.height, pixelWidthHeightRatio: pixelAspectRatio.ratio)
            }
        }
        if let aperture = extensions[kCMFormatDescriptionExtension_CleanAperture] as? [CFString: Any] {
            self.cleanAperture = Self.cleanAperture(of: aperture)
        }
        self.fieldCount = number(kCMFormatDescriptionExtension_FieldCount)
        self.fieldOrder = Self.value(named: string(kCMFormatDescriptionExtension_FieldDetail))
        self.bytesPerRow = number(kCMFormatDescriptionExtension_BytesPerRow)
        self.alphaChannelMode = Self.value(named: string(VideoKey.alphaChannelMode))
        self.containsAlphaChannel = extensions[VideoKey.containsAlphaChannel] as? Bool

        self.masteringDisplay = (extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data)
            .flatMap(MasteringDisplay.init(bytes:))
        self.contentLightLevel = (extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data)
            .flatMap(ContentLightLevel.init(bytes:))
        self.ambientViewingEnvironment = (extensions[VideoKey.ambientViewingEnvironment] as? Data)
            .flatMap(AmbientViewingEnvironment.init(bytes:))
        self.contentColorVolume = (extensions[VideoKey.contentColorVolume] as? Data).flatMap(ContentColorVolume.init(bytes:))
        readExtendedUsage(extensions)
    }

    mutating func readExtendedUsage(_ extensions: [CFString: Any]) {
        self.horizontalFieldOfView = (extensions[VideoKey.horizontalFieldOfView] as? NSNumber)?.intValue
        let stereoViews = Self.stereoViewKeys.reduce(into: StereoViews()) { views, entry in
            if extensions[entry.1] as? Bool == true { views.insert(entry.0) }
        }
        self.stereoViews = stereoViews.isEmpty ? nil : stereoViews
        self.heroEye = Self.value(named: extensions[VideoKey.heroEye] as? String)
        self.stereoCameraBaseline = (extensions[VideoKey.stereoCameraBaseline] as? NSNumber)?.uint32Value
        self.horizontalDisparityAdjustment = (extensions[VideoKey.horizontalDisparityAdjustment] as? NSNumber)?.int32Value
        self.transportIdentifier = (extensions[VideoKey.transportIdentifier] as? NSNumber)?.uint32Value
        self.projection = Self.value(named: extensions[VideoKey.projectionKind] as? String)
        self.viewPacking = Self.value(named: extensions[VideoKey.viewPackingKind] as? String)
        self.unrecognizedRequiredBoxPaths = (extensions[VideoKey.requiredButUnrecognizedFormatAtoms] as? [[NSNumber]])?
            .map { path in path.map { FourCharacterCode(UInt32(truncatingIfNeeded: $0.int64Value)) } }
    }

    static func cleanAperture(of dictionary: [CFString: Any]) -> CleanAperture? {
        func rational(_ key: CFString, _ rationalKey: CFString) -> Rational? {
            if let pair = dictionary[rationalKey] as? [NSNumber], pair.count == 2 {
                return Rational(numerator: pair[0].intValue, denominator: pair[1].intValue)
            }
            return (dictionary[key] as? NSNumber).map { Rational(numerator: $0.intValue, denominator: 1) }
        }
        guard let width = rational(kCMFormatDescriptionKey_CleanApertureWidth, kCMFormatDescriptionKey_CleanApertureWidthRational),
              let height = rational(kCMFormatDescriptionKey_CleanApertureHeight, kCMFormatDescriptionKey_CleanApertureHeightRational),
              let horizontal = rational(
                  kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
                  kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational
              ),
              let vertical = rational(
                  kCMFormatDescriptionKey_CleanApertureVerticalOffset,
                  kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational
              ) else {
            return nil
        }
        return CleanAperture(width: width, height: height, horizontalOffset: horizontal, verticalOffset: vertical)
    }
}

// MARK: - Names

private extension Format where Scope == FormatAttributes.Video {
    static func name(of transfer: TransferFunction) -> CFString? {
        CVTransferFunctionGetStringForIntegerCodePoint(Int32(transfer.rawValue))?.takeUnretainedValue()
    }

    /// The value of a type that descriptions name by `name`.
    static func value<Value: DescriptionNamed>(named name: String?) -> Value? {
        name.flatMap { name in Value.allCases.first { Self.name(of: $0) == name } }
    }

    static func name(of value: some DescriptionNamed) -> String {
        value.descriptionName
    }

    static var stereoViewKeys: [(StereoViews, CFString)] {
        [
            (.left, VideoKey.hasLeftStereoEyeView),
            (.right, VideoKey.hasRightStereoEyeView),
            (.additionalViews, VideoKey.hasAdditionalViews),
            (.eyesReversed, VideoKey.hasEyeViewsReversed),
        ]
    }

    /// The horizontal and vertical spacing of pixels, as the nearest fraction of small integers to `ratio`.
    static func fraction(of ratio: Float) -> (Int, Int) {
        // The convergents of the continued fraction, until one gives the ratio as a `Float` has it.
        var (horizontal, previousHorizontal) = (1, 0)
        var (vertical, previousVertical) = (0, 1)
        var remainder = Double(ratio)
        repeat {
            let term = Int(remainder.rounded(.down))
            (horizontal, previousHorizontal) = (term * horizontal + previousHorizontal, horizontal)
            (vertical, previousVertical) = (term * vertical + previousVertical, vertical)
            let fraction = remainder - Double(term)
            guard fraction > 0 else { break }
            remainder = 1 / fraction
        } while Float(horizontal) / Float(vertical) != ratio && vertical < 65536
        return (horizontal, vertical)
    }

    /// The codec type of a codec the container didn't name.
    static func codecType(of codec: VideoCodec?) throws -> FourCharCode {
        let codec = try codec.checkNotNil(FormatConversionError.missingAttribute("codec"))
        switch codec.mimeType {
        case .videoH264:
            return codec.h264.hasInBandParameterSets ? 0x6176_6333 : kCMVideoCodecType_H264 // avc3
        case .videoH265:
            return codec.hevc.hasInBandParameterSets ? 0x6865_7631 : kCMVideoCodecType_HEVC // hev1
        case .videoDolbyVision:
            switch codec.dolbyVision.baseLayer {
            case .videoH264?: return 0x6476_6131 // dva1
            case .videoAV1?: return 0x6461_7631 // dav1
            default: return kCMVideoCodecType_DolbyVisionHEVC
            }
        case .videoAV1:
            return kCMVideoCodecType_AV1
        case .videoVP9:
            return kCMVideoCodecType_VP9
        case .videoVP8:
            return 0x7670_3038 // vp08
        case .videoMP4V:
            return kCMVideoCodecType_MPEG4Video
        case .videoH263:
            return kCMVideoCodecType_H263
        case .videoMPEG2:
            return kCMVideoCodecType_MPEG2Video
        case .videoMPEG:
            return kCMVideoCodecType_MPEG1Video
        case .videoMJPEG:
            return kCMVideoCodecType_JPEG
        default:
            throw FormatConversionError.unsupportedCodec(codec.mimeType)
        }
    }
}

private extension Format where Scope == FormatAttributes.Video {
    /// The boxes whose content the extensions tell: descriptions don't keep them as they are.
    static var describedBoxes: Set<FourCharacterCode> {
        [
            "colr", "gama", "pasp", "clap", "fiel", "clli", "mdcv", "amve", "cclv", "chrm", "atch", "almo", "rowb",
            "hfov", "logs", "vexu", "jpgC",
        ]
    }
}

/// A value that format descriptions name by a string.
private protocol DescriptionNamed: CaseIterable {
    var descriptionName: String { get }
}

extension ChromaLocation: DescriptionNamed {
    fileprivate var descriptionName: String {
        let name = switch self {
        case .left: kCVImageBufferChromaLocation_Left
        case .center: kCVImageBufferChromaLocation_Center
        case .topLeft: kCVImageBufferChromaLocation_TopLeft
        case .top: kCVImageBufferChromaLocation_Top
        case .bottomLeft: kCVImageBufferChromaLocation_BottomLeft
        case .bottom: kCVImageBufferChromaLocation_Bottom
        case .dv420: kCVImageBufferChromaLocation_DV420
        }
        return name as String
    }
}

extension FieldOrder: DescriptionNamed {
    fileprivate var descriptionName: String {
        let name = switch self {
        case .temporalTopFirst: kCMFormatDescriptionFieldDetail_TemporalTopFirst
        case .temporalBottomFirst: kCMFormatDescriptionFieldDetail_TemporalBottomFirst
        case .spatialFirstLineEarly: kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
        case .spatialFirstLineLate: kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
        }
        return name as String
    }
}

extension AlphaChannelMode: DescriptionNamed {
    fileprivate var descriptionName: String {
        switch self {
        case .straight: "StraightAlpha"
        case .premultiplied: "PremultipliedAlpha"
        }
    }
}

extension HeroEye: DescriptionNamed {
    fileprivate var descriptionName: String {
        switch self {
        case .unspecified: "Unspecified"
        case .left: "Left"
        case .right: "Right"
        case .reserved: "Reserved"
        }
    }
}

extension VideoProjection: DescriptionNamed {
    fileprivate var descriptionName: String {
        switch self {
        case .rectilinear: "Rectilinear"
        case .equirectangular: "Equirectangular"
        case .halfEquirectangular: "HalfEquirectangular"
        case .appleImmersiveVideo: "AppleImmersiveVideo"
        case .parametricImmersive: "ParametricImmersive"
        }
    }
}

extension ViewPacking: DescriptionNamed {
    fileprivate var descriptionName: String {
        switch self {
        case .unspecified: "Unspecified"
        case .sideBySide: "SideBySide"
        case .overUnder: "OverUnder"
        }
    }
}

/// The names of the extensions that systems before iOS 17 have no constants for, or that have none.
private enum VideoKey {
    static var conformsToMPEG2VideoProfile: CFString { "ConformsToMPEG2VideoProfile" as CFString }
    static var alternativeTransferCharacteristics: CFString { "AlternativeTransferCharacteristics" as CFString }
    static var logTransferFunction: CFString { "LogTransferFunction" as CFString }
    static var bitsPerComponent: CFString { "BitsPerComponent" as CFString }
    static var alphaChannelMode: CFString { "AlphaChannelMode" as CFString }
    static var containsAlphaChannel: CFString { "ContainsAlphaChannel" as CFString }
    static var ambientViewingEnvironment: CFString { "AmbientViewingEnvironment" as CFString }
    static var contentColorVolume: CFString { "ContentColorVolume" as CFString }
    static var horizontalFieldOfView: CFString { "HorizontalFieldOfView" as CFString }
    static var hasLeftStereoEyeView: CFString { "HasLeftStereoEyeView" as CFString }
    static var hasRightStereoEyeView: CFString { "HasRightStereoEyeView" as CFString }
    static var hasAdditionalViews: CFString { "HasAdditionalViews" as CFString }
    static var hasEyeViewsReversed: CFString { "HasEyeViewsReversed" as CFString }
    static var heroEye: CFString { "HeroEye" as CFString }
    static var stereoCameraBaseline: CFString { "StereoCameraBaseline" as CFString }
    static var horizontalDisparityAdjustment: CFString { "HorizontalDisparityAdjustment" as CFString }
    static var transportIdentifier: CFString { "TransportIdentifier" as CFString }
    static var projectionKind: CFString { "ProjectionKind" as CFString }
    static var viewPackingKind: CFString { "ViewPackingKind" as CFString }
    static var requiredButUnrecognizedFormatAtoms: CFString { "RequiredButUnrecognizedFormatAtoms" as CFString }
}
