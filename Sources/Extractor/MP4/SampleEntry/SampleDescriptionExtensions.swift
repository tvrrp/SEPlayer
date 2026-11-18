//
//  SampleDescriptionExtensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// The keys of the format description extensions a sample entry describes.
///
/// Some of them are newer than the oldest system supported, so they are spelled out.
enum SampleDescriptionExtensionKey {
    static let verbatimSampleDescription = "VerbatimSampleDescription" as CFString
    static let verbatimISOSampleEntry = "VerbatimISOSampleEntry" as CFString
    static let sampleDescriptionExtensionAtoms = "SampleDescriptionExtensionAtoms" as CFString

    static let version = "Version" as CFString
    static let revisionLevel = "RevisionLevel" as CFString
    static let vendor = "Vendor" as CFString
    static let temporalQuality = "TemporalQuality" as CFString
    static let spatialQuality = "SpatialQuality" as CFString
    static let depth = "Depth" as CFString
    static let formatName = "FormatName" as CFString
    static let conformsToMPEG2VideoProfile = "ConformsToMPEG2VideoProfile" as CFString

    static let colorPrimaries = "CVImageBufferColorPrimaries" as CFString
    static let transferFunction = "CVImageBufferTransferFunction" as CFString
    static let yCbCrMatrix = "CVImageBufferYCbCrMatrix" as CFString
    static let gammaLevel = "CVImageBufferGammaLevel" as CFString
    static let iccProfile = "CVImageBufferICCProfile" as CFString
    static let fullRangeVideo = "FullRangeVideo" as CFString
    static let chromaLocationTopField = "CVImageBufferChromaLocationTopField" as CFString
    static let chromaLocationBottomField = "CVImageBufferChromaLocationBottomField" as CFString
    static let pixelAspectRatio = "CVPixelAspectRatio" as CFString
    static let cleanAperture = "CVCleanAperture" as CFString
    static let fieldCount = "CVFieldCount" as CFString
    static let fieldDetail = "CVFieldDetail" as CFString
    static let bytesPerRow = "CVBytesPerRow" as CFString

    static let masteringDisplayColorVolume = "MasteringDisplayColorVolume" as CFString
    static let contentLightLevelInfo = "ContentLightLevelInfo" as CFString
    static let ambientViewingEnvironment = "AmbientViewingEnvironment" as CFString
    static let contentColorVolume = "ContentColorVolume" as CFString
    static let alternativeTransferCharacteristics = "AlternativeTransferCharacteristics" as CFString
    static let alphaChannelMode = "AlphaChannelMode" as CFString
    static let containsAlphaChannel = "ContainsAlphaChannel" as CFString
    static let bitsPerComponent = "BitsPerComponent" as CFString
    static let horizontalFieldOfView = "HorizontalFieldOfView" as CFString
    static let logTransferFunction = "LogTransferFunction" as CFString

    static let commonEncryptionProtected = "CommonEncryptionProtected" as CFString
    static let commonEncryptionOriginalFormat = "CommonEncryptionOriginalFormat" as CFString
    static let commonEncryptionTrackEncryptionBox = "CommonEncryptionTrackEncryptionBox" as CFString

    static let hasLeftStereoEyeView = "HasLeftStereoEyeView" as CFString
    static let hasRightStereoEyeView = "HasRightStereoEyeView" as CFString
    static let hasAdditionalViews = "HasAdditionalViews" as CFString
    static let hasEyeViewsReversed = "HasEyeViewsReversed" as CFString
    static let heroEye = "HeroEye" as CFString
    static let stereoCameraBaseline = "StereoCameraBaseline" as CFString
    static let horizontalDisparityAdjustment = "HorizontalDisparityAdjustment" as CFString
    static let transportIdentifier = "TransportIdentifier" as CFString
    static let projectionKind = "ProjectionKind" as CFString
    static let viewPackingKind = "ViewPackingKind" as CFString
    static let requiredButUnrecognizedFormatAtoms = "RequiredButUnrecognizedFormatAtoms" as CFString
}

/// The extensions of a format description, built in the order a sample entry is read.
struct SampleDescriptionExtensions {
    var values: [CFString: Any] = [:]
    /// The boxes no extension describes, by type, in the order they came.
    private var unknownBoxes: [(type: UInt32, payload: BlockBufferReader)] = []

    subscript(key: CFString) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func contains(_ key: CFString) -> Bool {
        values[key] != nil
    }

    /// Sets `value` unless the key has one: of boxes describing the same thing, the first one wins.
    mutating func addFirst(_ value: Any, for key: CFString) {
        guard values[key] == nil else { return }
        values[key] = value
    }

    /// Keeps a box the decoder may need although no extension describes it, such as a decoder configuration.
    mutating func addUnknownBox(_ box: SampleEntryBox) {
        unknownBoxes.append((box.rawType, box.payload))
    }

    /// The payloads of the boxes of `type` kept so far.
    func unknownBoxPayloads(of type: MP4Box.BoxType) -> [BlockBufferReader] {
        unknownBoxes.filter { $0.type == type.rawValue }.map(\.payload)
    }

    /// The extensions, with the boxes no extension describes: each type's payload, or the payloads of a type that
    /// came more than once.
    func build() throws -> [CFString: Any] {
        var values = values
        if !unknownBoxes.isEmpty {
            var atoms: [String: Any] = [:]
            for type in Set(unknownBoxes.map(\.type)) {
                let payloads = try unknownBoxes.filter { $0.type == type }.map { try Data(buffer: $0.payload) }
                atoms[type.fourCharacterCode] = payloads.count == 1 ? payloads[0] : payloads
            }
            values[SampleDescriptionExtensionKey.sampleDescriptionExtensionAtoms] = atoms
        }
        return values
    }

    /// The whole sample entry, under the key of its flavor.
    mutating func setVerbatimEntry(_ entry: BlockBufferReader, isQuickTime: Bool) throws {
        let key = isQuickTime
            ? SampleDescriptionExtensionKey.verbatimSampleDescription
            : SampleDescriptionExtensionKey.verbatimISOSampleEntry
        values[key] = try Data(buffer: entry)
    }
}

extension SampleDescriptionExtensions {
    static func number(_ value: Int8) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt8Type, &value)
    }

    static func number(_ value: Int16) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt16Type, &value)
    }

    static func number(_ value: Int32) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value)
    }

    static func number(_ value: Int64) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &value)
    }

    static func number(_ value: Double) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .float64Type, &value)
    }

    /// An unsigned 32 bit value: of 32 bits while it fits them signed, of 64 bits otherwise.
    static func number(_ value: UInt32) -> CFNumber {
        value <= UInt32(Int32.max) ? number(Int32(value)) : number(Int64(value))
    }
}
