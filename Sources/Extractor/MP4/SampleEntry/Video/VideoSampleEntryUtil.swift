//
//  VideoSampleEntryUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import CoreMedia
import CoreVideo
import Foundation
import SEPlayerCommon

/// Helpers for reading video sample entries into format descriptions.
enum VideoSampleEntryUtil {
    /// The size of the fields of an image description, before its boxes.
    static let headerSize = 86

    // MARK: - Header

    /// The fields of an image description, ISO's VisualSampleEntry and QuickTime's alike.
    struct ImageDescriptionHeader {
        /// The entry up to its size field, its indices starting at 0.
        let entry: BlockBufferReader
        let rawFormat: UInt32
        let version: Int16
        let revisionLevel: Int16
        let vendor: UInt32
        let temporalQuality: Int32
        let spatialQuality: Int32
        let width: Int
        let height: Int
        let formatName: String
        let depth: Int
        let colorTableID: Int16

        init(entry fullEntry: BlockBufferReader) throws {
            var reader = fullEntry
            let declaredSize = Int(try reader.readInt(as: UInt32.self))
            guard declaredSize >= VideoSampleEntryUtil.headerSize, declaredSize <= fullEntry.readableBytes else {
                throw EndOfFileError()
            }
            entry = try fullEntry.getSlice(at: fullEntry.readerIndex, length: declaredSize)
            rawFormat = try reader.readInt(as: UInt32.self)
            try reader.skip(8) // reserved (6), data reference index (2)
            version = try reader.readInt(as: Int16.self)
            revisionLevel = try reader.readInt(as: Int16.self)
            vendor = try reader.readInt(as: UInt32.self)
            temporalQuality = try reader.readInt(as: Int32.self)
            spatialQuality = try reader.readInt(as: Int32.self)
            width = Int(try reader.readInt(as: UInt16.self))
            height = Int(try reader.readInt(as: UInt16.self))
            try reader.skip(14) // horizontal and vertical resolution (8), data size (4), frame count (2)

            // The name of the compressor, a Pascal string of up to 31 characters in 32 bytes, or the format in quotes.
            let nameField = try reader.readBytes(length: 32)
            let nameLength = Int(nameField[0])
            if (1...31).contains(nameLength), let name = String(bytes: nameField[1...nameLength], encoding: .macOSRoman) {
                formatName = name
            } else {
                formatName = "'\(rawFormat.fourCharacterCode)'"
            }

            depth = Int(try reader.readInt(as: Int16.self))
            colorTableID = try reader.readInt(as: Int16.self)
        }
    }

    // MARK: - Boxes

    /// Turns the boxes that describe the picture into extensions, and keeps the others. Of boxes that describe the
    /// same thing, the first one wins.
    ///
    /// - Returns: The protection of each `sinf` box, or `nil` for a box that can't be read and that the system would
    ///   refuse.
    static func readBoxes(_ boxes: [SampleEntryBox], into extensions: inout SampleDescriptionExtensions) -> [ProtectionScheme]? {
        typealias Key = SampleDescriptionExtensionKey
        var transferIsUnspecified = false
        var hasGamma = false
        var protection: [ProtectionScheme] = []
        for box in boxes {
            let payload = box.payload
            let size = payload.readableBytes
            switch box.type {
            case .colr:
                readColor(payload, into: &extensions, transferIsUnspecified: &transferIsUnspecified)
            case .gama:
                guard size == 4, let gamma = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                extensions.addFirst(SampleDescriptionExtensions.number(Double(gamma) / 65536), for: Key.gammaLevel)
                hasGamma = true
            case .pasp:
                guard size == 8, let horizontal = try? payload.getInt(at: 0, as: Int32.self),
                      let vertical = try? payload.getInt(at: 4, as: Int32.self),
                      horizontal > 0, vertical > 0 else {
                    continue
                }
                extensions.addFirst(pixelAspectRatio(horizontal: horizontal, vertical: vertical), for: Key.pixelAspectRatio)
            case .clap:
                guard let cleanAperture = cleanAperture(payload) else {
                    continue
                }
                extensions.addFirst(cleanAperture, for: Key.cleanAperture)
            case .fiel:
                guard size == 2, let count = try? payload.getInt(at: 0, as: UInt8.self),
                      let detail = try? payload.getInt(at: 1, as: UInt8.self) else {
                    continue
                }
                readFields(count: count, detail: detail, into: &extensions)
            case .clli:
                guard let data = try? Data(buffer: payload) else {
                    return nil
                }
                extensions.addFirst(data, for: Key.contentLightLevelInfo)
            case .mdcv:
                guard let data = try? Data(buffer: payload) else {
                    return nil
                }
                extensions.addFirst(data, for: Key.masteringDisplayColorVolume)
            case .amve:
                guard let data = try? Data(buffer: payload) else {
                    return nil
                }
                extensions.addFirst(data, for: Key.ambientViewingEnvironment)
            case .cclv:
                guard let data = try? Data(buffer: payload) else {
                    return nil
                }
                extensions.addFirst(data, for: Key.contentColorVolume)
            case .chrm:
                guard size == 2, let top = try? payload.getInt(at: 0, as: UInt8.self),
                      let bottom = try? payload.getInt(at: 1, as: UInt8.self) else {
                    continue
                }
                if let top = chromaLocation(Int(top)) { extensions.addFirst(top, for: Key.chromaLocationTopField) }
                if let bottom = chromaLocation(Int(bottom)) { extensions.addFirst(bottom, for: Key.chromaLocationBottomField) }
            case .atch:
                guard size == 1, let transfer = try? payload.getInt(at: 0, as: UInt8.self) else {
                    continue
                }
                if transfer != 0, let name = transferFunction(Int(transfer)) {
                    extensions.addFirst(name, for: Key.alternativeTransferCharacteristics)
                }
            case .almo:
                guard size == 4, let mode = try? payload.getInt(at: 0, as: UInt32.self) else {
                    continue
                }
                switch mode {
                case 0x100: extensions.addFirst("StraightAlpha", for: Key.alphaChannelMode)
                case 0x102: extensions.addFirst("PremultipliedAlpha", for: Key.alphaChannelMode)
                default: break
                }
            case .rowb:
                guard size == 4, let bytesPerRow = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                extensions.addFirst(SampleDescriptionExtensions.number(bytesPerRow), for: Key.bytesPerRow)
            case .hfov:
                // The horizontal field of view, in thousandths of a degree.
                guard size == 4, let fieldOfView = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                extensions.addFirst(SampleDescriptionExtensions.number(fieldOfView), for: Key.horizontalFieldOfView)
            case .logs:
                // The name of the log transfer function, such as Apple Log.
                guard size > 0, let bytes = try? payload.getBytes(at: 0, length: size),
                      let name = String(bytes: bytes, encoding: .isoLatin1) else {
                    continue
                }
                extensions.addFirst(name, for: Key.logTransferFunction)
            case .vexu:
                guard (try? VideoExtendedUsage.addExtensions(vexu: payload, to: &extensions)) != nil else {
                    return nil
                }
            case .sinf:
                let scheme = ProtectionScheme(sinf: payload)
                guard (try? scheme.addExtensions(to: &extensions)) != nil else {
                    return nil
                }
                protection.append(scheme)
                extensions.addUnknownBox(box)
            case .jpgC:
                guard size == 0 else {
                    return nil
                }
            case .free:
                break
            default:
                extensions.addUnknownBox(box)
            }
        }
        // An unspecified transfer function of `colr` is the gamma of `gama`.
        if transferIsUnspecified, hasGamma {
            extensions[Key.transferFunction] = kCVImageBufferTransferFunction_UseGamma
        }
        return protection
    }

    /// A `colr` box: the code points of `nclc` or `nclx`, or an ICC profile.
    static func readColor(
        _ payload: BlockBufferReader,
        into extensions: inout SampleDescriptionExtensions,
        transferIsUnspecified: inout Bool
    ) {
        let type = (try? payload.getInt(at: 0, as: UInt32.self)).flatMap(MP4Box.BoxType.init(rawValue:))
        switch type {
        case .nclc? where payload.readableBytes == 10, .nclx? where payload.readableBytes == 11:
            var reader = payload
            guard let color = try? ColorInfo(reader: &reader) else {
                return
            }
            if color.transfer == 2 { transferIsUnspecified = true }
            addColorCodePoints(primaries: color.primaries, transfer: color.transfer, matrix: color.matrix, to: &extensions)
            if type == .nclx {
                extensions.addFirst(color.isFullRange, for: SampleDescriptionExtensionKey.fullRangeVideo)
            }
        case .prof?, .rICC?:
            guard let profile = try? payload.slice(from: 4), let data = try? Data(buffer: profile) else {
                return
            }
            extensions.addFirst(data, for: SampleDescriptionExtensionKey.iccProfile)
        default:
            break
        }
    }

    /// A `clap` box: the width, height and offsets of the clean aperture as fractions, with the fractions themselves
    /// where their denominator isn't 1.
    static func cleanAperture(_ payload: BlockBufferReader) -> [String: Any]? {
        guard payload.readableBytes == 32,
              let fields = try? (0..<8).map({ try payload.getInt(at: $0 * 4, as: UInt32.self) }) else {
            return nil
        }
        // widthN, widthD, heightN, heightD, horizOffN, horizOffD, vertOffN, vertOffD
        guard !fields[0..<4].contains(0), fields[5] != 0, fields[7] != 0 else {
            return nil
        }
        let number = { (value: UInt32) in SampleDescriptionExtensions.number(Int32(bitPattern: value)) }
        let horizontalOffset = Int32(bitPattern: fields[4]), verticalOffset = Int32(bitPattern: fields[6])
        var aperture: [String: Any] = [
            "Width": SampleDescriptionExtensions.number(Double(fields[0]) / Double(fields[1])),
            "Height": SampleDescriptionExtensions.number(Double(fields[2]) / Double(fields[3])),
            "HorizontalOffset": SampleDescriptionExtensions.number(Double(horizontalOffset) / Double(fields[5])),
            "VerticalOffset": SampleDescriptionExtensions.number(Double(verticalOffset) / Double(fields[7])),
        ]
        if fields[1] != 1 { aperture["WidthAsRational"] = [number(fields[0]), number(fields[1])] }
        if fields[3] != 1 { aperture["HeightAsRational"] = [number(fields[2]), number(fields[3])] }
        if fields[5] != 1 { aperture["HorizontalOffsetAsRational"] = [number(fields[4]), number(fields[5])] }
        if fields[7] != 1 { aperture["VerticalOffsetAsRational"] = [number(fields[6]), number(fields[7])] }
        return aperture
    }

    /// A `fiel` box: the field count, and with two fields their order.
    static func readFields(count: UInt8, detail: UInt8, into extensions: inout SampleDescriptionExtensions) {
        extensions.addFirst(SampleDescriptionExtensions.number(Int8(bitPattern: count)), for: SampleDescriptionExtensionKey.fieldCount)
        guard count > 1 else {
            return
        }
        let fieldDetail: String? = switch detail {
        case 1: "TemporalTopFirst"
        case 6: "TemporalBottomFirst"
        case 9: "SpatialFirstLineEarly"
        case 14: "SpatialFirstLineLate"
        default: nil
        }
        if let fieldDetail {
            extensions.addFirst(fieldDetail, for: SampleDescriptionExtensionKey.fieldDetail)
        }
    }

    // MARK: - Parameter sets

    /// The codecs whose parameter sets tell what the boxes leave out, with the types of their protected and Dolby
    /// Vision variants.
    enum ParameterSetFlavor {
        case h264
        case h265
        case av1

        init?(codecType: MP4Box.BoxType) {
            switch codecType {
            case .avc1, .avc3, .cavc, .qavc, .qave, .drmi, .eavc, .ftvc, .zavc:
                self = .h264
            case .hvc1, .hev1, .dvh1, .dvhe, .chvc, .qhvc, .qhev, .cdh1, .qdh1, .qdhe, .dmux, .ftvh, .ftvp, .muxa, .ohvc,
                 .qdmx, .qmux:
                self = .h265
            case .av01, .dav1, .qav1, .qdav:
                self = .av1
            default:
                return nil
            }
        }

        var configType: MP4Box.BoxType {
            switch self {
            case .h264: .avcC
            case .h265: .hvcC
            case .av1: .av1C
            }
        }
    }

    /// The twin of a type that lets the samples carry the parameter sets (`avc3`, `hev1`, `dvhe`) when its config has
    /// them all the same: decoders only know the twin (`avc1`, `hvc1`, `dvh1`), and the two decode alike.
    ///
    /// - Returns: `nil` for other types, and for a config that leaves a parameter set to the samples.
    static func twinWithParameterSetsInConfig(
        of codec: MP4Box.BoxType,
        extensions: SampleDescriptionExtensions
    ) -> MP4Box.BoxType? {
        switch codec {
        case .avc3:
            guard let avcC = extensions.unknownBoxPayloads(of: .avcC).first, AvcUtil.hasParameterSets(avcC: avcC) else {
                return nil
            }
            return .avc1
        case .hev1, .dvhe:
            let types = [HevcUtil.videoParameterSetType, HevcUtil.sequenceParameterSetType, HevcUtil.pictureParameterSetType]
            guard let hvcC = extensions.unknownBoxPayloads(of: .hvcC).first,
                  let arrays = HevcUtil.nalUnits(hvcC: hvcC),
                  types.allSatisfy({ HevcUtil.firstNalUnit(of: $0, in: arrays) != nil }) else {
                return nil
            }
            return codec == .hev1 ? .hvc1 : .dvh1
        default:
            return nil
        }
    }

    /// Adds the extensions the parameter sets tell and the boxes left out: chroma location, color, range, pixel
    /// aspect ratio, progressive frames, the HDR metadata of H.265 SEI messages, alpha and bit depth.
    ///
    /// - Returns: `false` for parameters not read here.
    static func addFallbackExtensions(
        to values: inout [CFString: Any],
        flavor: ParameterSetFlavor,
        extensions: SampleDescriptionExtensions
    ) -> Bool {
        typealias Key = SampleDescriptionExtensionKey
        // Without its config, or with one that doesn't read, the codec tells nothing more.
        guard let config = extensions.unknownBoxPayloads(of: flavor.configType).first else {
            return true
        }

        var parameters = FallbackParameters()
        switch flavor {
        case .h264:
            guard let sps = AvcUtil.firstSequenceParameterSet(avcC: config) else {
                return true
            }
            let view = BlockBufferView(sps)
            guard let parsed = try? NalUnitUtil.SpsData(data: view, nalOffset: view.startIndex + 1, nalLimit: view.endIndex) else {
                return true
            }
            parameters = FallbackParameters(h264: parsed)
        case .h265:
            guard let arrays = HevcUtil.nalUnits(hvcC: config) else {
                return true
            }
            let sps = HevcUtil.firstNalUnit(of: HevcUtil.sequenceParameterSetType, in: arrays)
                .flatMap { try? HevcUtil.SequenceParameterSet(nalUnit: $0) }
            parameters = FallbackParameters(h265: sps)
            parameters.masteringDisplay = HevcUtil.seiPayload(type: 137, in: arrays).flatMap { $0.count == 24 ? $0 : nil }
            parameters.contentLightLevel = HevcUtil.seiPayload(type: 144, in: arrays).flatMap { $0.count == 4 ? $0 : nil }
            parameters.ambientViewing = HevcUtil.seiPayload(type: 148, in: arrays).flatMap { $0.count == 8 ? $0 : nil }
            parameters.contentColorVolume = HevcUtil.seiPayload(type: 149, in: arrays)
            parameters.alternativeTransfer = HevcUtil.seiPayload(type: 147, in: arrays).flatMap { $0.count == 1 ? Int($0[0]) : nil }
            parameters.alphaIsPremultiplied = HevcUtil.seiPayload(type: 165, in: arrays).flatMap(HevcUtil.isAlphaPremultiplied)
            parameters.hasAlphaLayer = HevcUtil.firstNalUnit(of: HevcUtil.videoParameterSetType, in: arrays)
                .map(HevcUtil.hasAlphaLayer(videoParameterSet:)) ?? false
        case .av1:
            guard let av1 = Av1Configuration(av1C: config) else {
                return true
            }
            // HDR metadata in the config needs converting as the system does; the system reads those.
            guard !av1.hasMetadata else {
                return false
            }
            parameters = FallbackParameters(av1: av1)
        }

        func addIfAbsent(_ key: CFString, _ value: Any?) {
            guard values[key] == nil, let value else {
                return
            }
            values[key] = value
        }

        if values[Key.chromaLocationTopField] == nil {
            var (top, bottom) = parameters.chromaLocation ?? (0, 0)
            if flavor == .h264, top == 2, bottom == 2 { (top, bottom) = (1, 1) }
            addIfAbsent(Key.chromaLocationTopField, chromaLocation(top))
            addIfAbsent(Key.chromaLocationBottomField, chromaLocation(bottom))
        }
        if values[Key.colorPrimaries] == nil, let colour = parameters.colour {
            var colorExtensions = SampleDescriptionExtensions()
            addColorCodePoints(primaries: colour.primaries, transfer: colour.transfer, matrix: colour.matrix, to: &colorExtensions)
            values.merge(colorExtensions.values) { _, new in new }
        }
        addIfAbsent(Key.fullRangeVideo, parameters.fullRange)
        if let (horizontal, vertical) = parameters.sampleAspectRatio {
            addIfAbsent(Key.pixelAspectRatio, pixelAspectRatio(horizontal: Int32(horizontal), vertical: Int32(vertical)))
        }
        if parameters.isProgressive == true {
            addIfAbsent(Key.fieldCount, SampleDescriptionExtensions.number(Int32(1)))
        }
        addIfAbsent(Key.masteringDisplayColorVolume, parameters.masteringDisplay.map { Data($0) })
        addIfAbsent(Key.contentLightLevelInfo, parameters.contentLightLevel.map { Data($0) })
        addIfAbsent(Key.ambientViewingEnvironment, parameters.ambientViewing.map { Data($0) })
        addIfAbsent(Key.contentColorVolume, parameters.contentColorVolume.map { Data($0) })
        addIfAbsent(Key.alternativeTransferCharacteristics, parameters.alternativeTransfer.flatMap(transferFunction))
        addIfAbsent(Key.alphaChannelMode, parameters.alphaIsPremultiplied.map { $0 ? "PremultipliedAlpha" : "StraightAlpha" })
        if parameters.hasAlphaLayer {
            addIfAbsent(Key.containsAlphaChannel, true)
        }
        addIfAbsent(Key.bitsPerComponent, parameters.bitsPerComponent.map { SampleDescriptionExtensions.number(Int8(clamping: $0)) })

        // H.265 can name a transfer function for displays that know it, which wins over the usual one.
        if flavor == .h265, let alternative = values[Key.alternativeTransferCharacteristics] {
            values[Key.transferFunction] = alternative
        }
        return true
    }

    /// What the parameter sets tell of the pictures.
    struct FallbackParameters {
        var chromaLocation: (Int, Int)?
        var colour: (primaries: Int, transfer: Int, matrix: Int)?
        var fullRange: Bool?
        var sampleAspectRatio: (Int, Int)?
        var isProgressive: Bool?
        var bitsPerComponent: Int?
        var masteringDisplay: [UInt8]?
        var contentLightLevel: [UInt8]?
        var ambientViewing: [UInt8]?
        var contentColorVolume: [UInt8]?
        var alternativeTransfer: Int?
        var alphaIsPremultiplied: Bool?
        var hasAlphaLayer = false

        init() {}

        init(h264 sps: NalUnitUtil.SpsData) {
            self.init(vui: sps.vui)
            isProgressive = sps.frameMbsOnlyFlag
            // The range flag is 0 when the VUI has no video signal type.
            if sps.vui != nil { fullRange = fullRange ?? false }
        }

        init(h265 sps: HevcUtil.SequenceParameterSet?) {
            self.init(vui: sps?.vui)
            if let sps {
                isProgressive = !sps.isInterlaced
                bitsPerComponent = max(sps.bitDepthLuma, sps.bitDepthChroma)
                // The range flag is 0 when the parameter set has no VUI or the VUI no video signal type.
                fullRange = fullRange ?? false
            }
        }

        init(av1: Av1Configuration) {
            chromaLocation = (av1.chromaLocationIndex, av1.chromaLocationIndex)
            if let color = av1.colorConfig {
                colour = (color.colorPrimaries, color.transferCharacteristics, color.matrixCoefficients)
                fullRange = color.isFullRange
            }
            bitsPerComponent = av1.bitDepth
            // AV1 codes frames only.
            isProgressive = true
        }

        private init(vui: VideoUsabilityInformation?) {
            chromaLocation = vui?.chromaSampleLocation.map { ($0.topField, $0.bottomField) }
            colour = vui?.colourDescription.map { ($0.colourPrimaries, $0.transferCharacteristics, $0.matrixCoefficients) }
            fullRange = vui?.videoFullRange
            sampleAspectRatio = vui?.aspectRatio.map { _ in vui?.sampleAspectRatio ?? (0, 0) }
        }
    }

    static func addProResExtensions(to values: inout [CFString: Any], codecType: MP4Box.BoxType, depth: Int) {
        if values[SampleDescriptionExtensionKey.bitsPerComponent] == nil {
            values[SampleDescriptionExtensionKey.bitsPerComponent] =
                SampleDescriptionExtensions.number(Int32(ProResUtil.bitsPerComponent(format: codecType, depth: depth)))
        }
        // ProRes of 32 bits carries alpha, straight unless the entry says otherwise.
        if depth == 32 {
            if values[SampleDescriptionExtensionKey.containsAlphaChannel] == nil {
                values[SampleDescriptionExtensionKey.containsAlphaChannel] = true
            }
            if values[SampleDescriptionExtensionKey.alphaChannelMode] == nil {
                values[SampleDescriptionExtensionKey.alphaChannelMode] = "StraightAlpha"
            }
        }
    }

    // MARK: - Values

    /// Adds the color primaries, transfer function and matrix of ISO/IEC 23091-2 code points that have names.
    static func addColorCodePoints(
        primaries: Int,
        transfer: Int,
        matrix: Int,
        to extensions: inout SampleDescriptionExtensions
    ) {
        if let name = CVColorPrimariesGetStringForIntegerCodePoint(Int32(primaries))?.takeUnretainedValue() {
            extensions.addFirst(name, for: SampleDescriptionExtensionKey.colorPrimaries)
        }
        if let name = transferFunction(transfer) {
            extensions.addFirst(name, for: SampleDescriptionExtensionKey.transferFunction)
        }
        if let name = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(matrix))?.takeUnretainedValue() {
            extensions.addFirst(name, for: SampleDescriptionExtensionKey.yCbCrMatrix)
        }
    }

    static func transferFunction(_ codePoint: Int) -> CFString? {
        CVTransferFunctionGetStringForIntegerCodePoint(Int32(codePoint))?.takeUnretainedValue()
    }

    /// The chroma location of an index of H.264 Table E-1's chroma sample locations, or 255 for DV 4:2:0.
    static func chromaLocation(_ index: Int) -> CFString? {
        switch index {
        case 0: kCVImageBufferChromaLocation_Left
        case 1: kCVImageBufferChromaLocation_Center
        case 2: kCVImageBufferChromaLocation_TopLeft
        case 3: kCVImageBufferChromaLocation_Top
        case 4: kCVImageBufferChromaLocation_BottomLeft
        case 5: kCVImageBufferChromaLocation_Bottom
        case 255: kCVImageBufferChromaLocation_DV420
        default: nil
        }
    }

    static func pixelAspectRatio(horizontal: Int32, vertical: Int32) -> [CFString: Any] {
        [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: SampleDescriptionExtensions.number(horizontal),
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: SampleDescriptionExtensions.number(vertical),
        ]
    }
}
