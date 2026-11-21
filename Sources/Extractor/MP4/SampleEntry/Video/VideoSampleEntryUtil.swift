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
            let declaredSize = try Int(reader.readInt(as: UInt32.self))
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
            width = try Int(reader.readInt(as: UInt16.self))
            height = try Int(reader.readInt(as: UInt16.self))
            try reader.skip(14) // horizontal and vertical resolution (8), data size (4), frame count (2)

            // The name of the compressor, a Pascal string of up to 31 characters in 32 bytes, or the format in quotes.
            let nameField = try reader.readBytes(length: 32)
            let nameLength = Int(nameField[0])
            if (1 ... 31).contains(nameLength), let name = String(bytes: nameField[1 ... nameLength], encoding: .macOSRoman) {
                formatName = name
            } else {
                formatName = "'\(rawFormat.fourCharacterCode)'"
            }

            depth = try Int(reader.readInt(as: Int16.self))
            colorTableID = try reader.readInt(as: Int16.self)
        }
    }

    // MARK: - Boxes

    /// Reads the boxes that describe the picture into the format. Of boxes that describe the same thing, the first
    /// one wins.
    ///
    /// - Returns: The protection of each `sinf` box, or `nil` for a box that can't be read and that the system would
    ///   refuse.
    static func readBoxes(_ boxes: [SampleEntryBox], into format: inout VideoFormat) -> [ProtectionScheme]? {
        var transferIsUnspecified = false
        var hasGamma = false
        var protection: [ProtectionScheme] = []
        for box in boxes {
            let payload = box.payload
            let size = payload.readableBytes
            switch box.type {
            case .colr:
                readColor(payload, into: &format, transferIsUnspecified: &transferIsUnspecified)
            case .gama:
                guard size == 4, let gamma = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                format.gammaLevel = format.gammaLevel ?? Double(gamma) / 65536
                hasGamma = true
            case .pasp:
                guard size == 8, let horizontal = try? payload.getInt(at: 0, as: Int32.self),
                      let vertical = try? payload.getInt(at: 4, as: Int32.self),
                      horizontal > 0, vertical > 0 else {
                    continue
                }
                format.pixelAspectRatio = format.pixelAspectRatio
                    ?? PixelAspectRatio(horizontalSpacing: Int(horizontal), verticalSpacing: Int(vertical))
            case .clap:
                format.cleanAperture = format.cleanAperture ?? cleanAperture(payload)
            case .fiel:
                guard size == 2, let count = try? payload.getInt(at: 0, as: UInt8.self),
                      let detail = try? payload.getInt(at: 1, as: UInt8.self) else {
                    continue
                }
                readFields(count: count, detail: detail, into: &format)
            case .clli:
                format.contentLightLevel = format.contentLightLevel ?? ContentLightLevel(bytes: BlockBufferView(payload))
            case .mdcv:
                format.masteringDisplay = format.masteringDisplay ?? MasteringDisplay(bytes: BlockBufferView(payload))
            case .amve:
                format.ambientViewingEnvironment = format.ambientViewingEnvironment
                    ?? AmbientViewingEnvironment(bytes: BlockBufferView(payload))
            case .cclv:
                format.contentColorVolume = format.contentColorVolume ?? ContentColorVolume(bytes: BlockBufferView(payload))
            case .chrm:
                guard size == 2, let top = try? payload.getInt(at: 0, as: UInt8.self),
                      let bottom = try? payload.getInt(at: 1, as: UInt8.self) else {
                    continue
                }
                format.chromaLocationTopField = format.chromaLocationTopField ?? ChromaLocation(rawValue: Int(top))
                format.chromaLocationBottomField = format.chromaLocationBottomField ?? ChromaLocation(rawValue: Int(bottom))
            case .atch:
                guard size == 1, let transfer = try? payload.getInt(at: 0, as: UInt8.self) else {
                    continue
                }
                let alternative = TransferFunction(rawValue: Int(transfer))
                if transfer != 0, hasName(alternative) {
                    format.alternativeTransferFunction = format.alternativeTransferFunction ?? alternative
                }
            case .almo:
                guard size == 4, let mode = try? payload.getInt(at: 0, as: UInt32.self) else {
                    continue
                }
                switch mode {
                case 0x100: format.alphaChannelMode = format.alphaChannelMode ?? .straight
                case 0x102: format.alphaChannelMode = format.alphaChannelMode ?? .premultiplied
                default: break
                }
            case .rowb:
                guard size == 4, let bytesPerRow = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                format.bytesPerRow = format.bytesPerRow ?? Int(bytesPerRow)
            case .hfov:
                // The horizontal field of view, in thousandths of a degree.
                guard size == 4, let fieldOfView = try? payload.getInt(at: 0, as: Int32.self) else {
                    continue
                }
                format.horizontalFieldOfView = format.horizontalFieldOfView ?? Int(fieldOfView)
            case .logs:
                // The name of the log transfer function, such as Apple Log.
                guard size > 0, let bytes = try? payload.getBytes(at: 0, length: size),
                      let name = String(bytes: bytes, encoding: .isoLatin1) else {
                    continue
                }
                format.logTransferFunction = format.logTransferFunction ?? name
            case .vexu:
                guard (try? VideoExtendedUsage.read(vexu: payload, into: &format)) != nil else {
                    return nil
                }
            case .sinf:
                let scheme = ProtectionScheme(sinf: payload)
                guard (try? scheme.apply(to: &format)) != nil else {
                    return nil
                }
                protection.append(scheme)
            case .jpgC:
                guard size == 0 else {
                    return nil
                }
            default:
                break
            }
        }
        // An unspecified transfer function of `colr` is the gamma of `gama`, which descriptions name by the gamma.
        if transferIsUnspecified, hasGamma {
            format.transferFunction = .unspecified
        }
        return protection
    }

    /// A `colr` box: the code points of `nclc` or `nclx`, or an ICC profile.
    static func readColor(
        _ payload: BlockBufferReader,
        into format: inout VideoFormat,
        transferIsUnspecified: inout Bool
    ) {
        let type = (try? payload.getInt(at: 0, as: UInt32.self)).flatMap(MP4Box.BoxType.init(rawValue:))
        switch type {
        case .nclc? where payload.readableBytes == 10,
             .nclx? where payload.readableBytes == 11:
            var reader = payload
            guard let color = try? ColorInfo(reader: &reader) else {
                return
            }
            if color.transfer == 2 { transferIsUnspecified = true }
            format.colorPrimaries = format.colorPrimaries ?? ColorPrimaries(rawValue: color.primaries)
            format.transferFunction = format.transferFunction ?? TransferFunction(rawValue: color.transfer)
            format.matrixCoefficients = format.matrixCoefficients ?? MatrixCoefficients(rawValue: color.matrix)
            if type == .nclx {
                format.isFullRange = format.isFullRange ?? color.isFullRange
            }
        case .prof?,
             .rICC?:
            guard let profile = try? payload.slice(from: 4), let data = try? profile.readableData() else {
                return
            }
            format.iccProfile = format.iccProfile ?? data
        default:
            break
        }
    }

    /// A `clap` box: the width, height and offsets of the clean aperture as fractions.
    static func cleanAperture(_ payload: BlockBufferReader) -> CleanAperture? {
        guard payload.readableBytes == 32,
              let fields = try? (0 ..< 8).map({ try payload.getInt(at: $0 * 4, as: UInt32.self) }) else {
            return nil
        }
        // widthN, widthD, heightN, heightD, horizOffN, horizOffD, vertOffN, vertOffD
        guard !fields[0 ..< 4].contains(0), fields[5] != 0, fields[7] != 0 else {
            return nil
        }
        return CleanAperture(
            width: Rational(numerator: Int(fields[0]), denominator: Int(fields[1])),
            height: Rational(numerator: Int(fields[2]), denominator: Int(fields[3])),
            horizontalOffset: Rational(numerator: Int(Int32(bitPattern: fields[4])), denominator: Int(fields[5])),
            verticalOffset: Rational(numerator: Int(Int32(bitPattern: fields[6])), denominator: Int(fields[7]))
        )
    }

    /// A `fiel` box: the field count, and with two fields their order.
    static func readFields(count: UInt8, detail: UInt8, into format: inout VideoFormat) {
        guard format.fieldCount == nil else {
            return
        }
        format.fieldCount = Int(Int8(bitPattern: count))
        guard count > 1 else {
            return
        }
        format.fieldOrder = switch detail {
        case 1: .temporalTopFirst
        case 6: .temporalBottomFirst
        case 9: .spatialFirstLineEarly
        case 14: .spatialFirstLineLate
        default: nil
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
            case .avc1,
                 .avc3,
                 .cavc,
                 .qavc,
                 .qave,
                 .drmi,
                 .eavc,
                 .ftvc,
                 .zavc:
                self = .h264
            case .hvc1,
                 .hev1,
                 .dvh1,
                 .dvhe,
                 .chvc,
                 .qhvc,
                 .qhev,
                 .cdh1,
                 .qdh1,
                 .qdhe,
                 .dmux,
                 .ftvh,
                 .ftvp,
                 .muxa,
                 .ohvc,
                 .qdmx,
                 .qmux:
                self = .h265
            case .av01,
                 .dav1,
                 .qav1,
                 .qdav:
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
    static func twinWithParameterSetsInConfig(of codec: MP4Box.BoxType, boxes: [SampleEntryBox]) -> MP4Box.BoxType? {
        switch codec {
        case .avc3:
            guard let avcC = boxes.payload(of: .avcC), AvcUtil.hasParameterSets(avcC: avcC) else {
                return nil
            }
            return .avc1
        case .hev1,
             .dvhe:
            let types = [HevcUtil.videoParameterSetType, HevcUtil.sequenceParameterSetType, HevcUtil.pictureParameterSetType]
            guard let hvcC = boxes.payload(of: .hvcC),
                  let arrays = HevcUtil.nalUnits(hvcC: hvcC),
                  types.allSatisfy({ HevcUtil.firstNalUnit(of: $0, in: arrays) != nil }) else {
                return nil
            }
            return codec == .hev1 ? .hvc1 : .dvh1
        default:
            return nil
        }
    }

    /// Adds what the parameter sets of the configuration tell where the boxes told nothing: chroma location, color,
    /// range, pixel aspect ratio, progressive frames, the HDR metadata of H.265 SEI messages, alpha and bit depth.
    ///
    /// - Parameter config: The configuration box of the flavor, such as `avcC`.
    /// - Returns: `false` for parameters not read here.
    static func addParameterSetAttributes(
        to format: inout VideoFormat,
        config: BlockBufferReader?,
        flavor: ParameterSetFlavor
    ) -> Bool {
        // Without its config, or with one that doesn't read, the codec tells nothing more.
        guard let config, let parameters = FallbackParameters(config: config, flavor: flavor) else {
            return config.map { FallbackParameters.isRead(config: $0, flavor: flavor) } ?? true
        }

        if format.chromaLocationTopField == nil {
            var (top, bottom) = parameters.chromaLocation ?? (0, 0)
            if flavor == .h264, top == 2, bottom == 2 { (top, bottom) = (1, 1) }
            format.chromaLocationTopField = ChromaLocation(rawValue: top)
            format.chromaLocationBottomField = format.chromaLocationBottomField ?? ChromaLocation(rawValue: bottom)
        }
        // The colour of the parameter sets, where they name it, replaces a colour without named primaries.
        if !hasName(format.colorPrimaries), let colour = parameters.colour {
            let primaries = ColorPrimaries(rawValue: colour.primaries)
            let transfer = TransferFunction(rawValue: colour.transfer)
            let matrix = MatrixCoefficients(rawValue: colour.matrix)
            if hasName(primaries) { format.colorPrimaries = primaries }
            if hasName(transfer) { format.transferFunction = transfer }
            if hasName(matrix) { format.matrixCoefficients = matrix }
        }
        format.isFullRange = format.isFullRange ?? parameters.fullRange
        if let (horizontal, vertical) = parameters.sampleAspectRatio {
            format.pixelAspectRatio = format.pixelAspectRatio
                ?? PixelAspectRatio(horizontalSpacing: horizontal, verticalSpacing: vertical)
        }
        if parameters.isProgressive == true {
            format.fieldCount = format.fieldCount ?? 1
        }
        format.masteringDisplay = format.masteringDisplay ?? parameters.masteringDisplay
        format.contentLightLevel = format.contentLightLevel ?? parameters.contentLightLevel
        format.ambientViewingEnvironment = format.ambientViewingEnvironment ?? parameters.ambientViewing
        format.contentColorVolume = format.contentColorVolume ?? parameters.contentColorVolume
        if let alternative = parameters.alternativeTransfer, hasName(alternative) {
            format.alternativeTransferFunction = format.alternativeTransferFunction ?? alternative
        }
        format.alphaChannelMode = format.alphaChannelMode ?? parameters.alphaChannelMode
        if parameters.hasAlphaLayer {
            format.containsAlphaChannel = format.containsAlphaChannel ?? true
        }
        format.bitsPerComponent = format.bitsPerComponent ?? parameters.bitsPerComponent

        // H.265 can name a transfer function for displays that know it, which wins over the usual one.
        if flavor == .h265, let alternative = format.alternativeTransferFunction {
            format.transferFunction = alternative
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
        var masteringDisplay: MasteringDisplay?
        var contentLightLevel: ContentLightLevel?
        var ambientViewing: AmbientViewingEnvironment?
        var contentColorVolume: ContentColorVolume?
        var alternativeTransfer: TransferFunction?
        var alphaChannelMode: AlphaChannelMode?
        var hasAlphaLayer = false

        /// The parameters of a configuration box, or `nil` for one that doesn't read or tells nothing here.
        init?(config: BlockBufferReader, flavor: ParameterSetFlavor) {
            switch flavor {
            case .h264:
                guard let sps = AvcUtil.firstSequenceParameterSet(avcC: config) else {
                    return nil
                }
                let view = BlockBufferView(sps)
                guard let parsed = try? NalUnitUtil.SpsData(data: view, nalOffset: view.startIndex + 1, nalLimit: view.endIndex) else {
                    return nil
                }
                self.init(h264: parsed)
            case .h265:
                guard let arrays = HevcUtil.nalUnits(hvcC: config) else {
                    return nil
                }
                let sps = HevcUtil.firstNalUnit(of: HevcUtil.sequenceParameterSetType, in: arrays)
                    .flatMap { try? HevcUtil.SequenceParameterSet(nalUnit: $0) }
                self.init(h265: sps)
                masteringDisplay = HevcUtil.seiPayload(type: 137, in: arrays).flatMap(MasteringDisplay.init(bytes:))
                contentLightLevel = HevcUtil.seiPayload(type: 144, in: arrays).flatMap(ContentLightLevel.init(bytes:))
                ambientViewing = HevcUtil.seiPayload(type: 148, in: arrays).flatMap(AmbientViewingEnvironment.init(bytes:))
                contentColorVolume = HevcUtil.seiPayload(type: 149, in: arrays).flatMap(ContentColorVolume.init(bytes:))
                alternativeTransfer = HevcUtil.seiPayload(type: 147, in: arrays)
                    .flatMap { $0.count == 1 ? TransferFunction(rawValue: Int($0[0])) : nil }
                alphaChannelMode = HevcUtil.seiPayload(type: 165, in: arrays).flatMap(HevcUtil.isAlphaPremultiplied)
                    .map { $0 ? .premultiplied : .straight }
                hasAlphaLayer = HevcUtil.firstNalUnit(of: HevcUtil.videoParameterSetType, in: arrays)
                    .map(HevcUtil.hasAlphaLayer(videoParameterSet:)) ?? false
            case .av1:
                guard let av1 = Av1Configuration(av1C: config), !av1.hasMetadata else {
                    return nil
                }
                self.init(av1: av1)
            }
        }

        /// Whether a configuration box that gives no parameters is still read here: all but AV1 with HDR metadata,
        /// which needs converting as the system does.
        static func isRead(config: BlockBufferReader, flavor: ParameterSetFlavor) -> Bool {
            guard flavor == .av1, let av1 = Av1Configuration(av1C: config) else {
                return true
            }
            return !av1.hasMetadata
        }

        private init() {}

        private init(h264 sps: NalUnitUtil.SpsData) {
            self.init(vui: sps.vui)
            isProgressive = sps.frameMbsOnlyFlag
            // The range flag is 0 when the VUI has no video signal type.
            if sps.vui != nil { fullRange = fullRange ?? false }
        }

        private init(h265 sps: HevcUtil.SequenceParameterSet?) {
            self.init(vui: sps?.vui)
            if let sps {
                isProgressive = !sps.isInterlaced
                bitsPerComponent = max(sps.bitDepthLuma, sps.bitDepthChroma)
                // The range flag is 0 when the parameter set has no VUI or the VUI no video signal type.
                fullRange = fullRange ?? false
            }
        }

        private init(av1: Av1Configuration) {
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

    static func addProResAttributes(to format: inout VideoFormat, codecType: MP4Box.BoxType, depth: Int) {
        format.bitsPerComponent = format.bitsPerComponent ?? ProResUtil.bitsPerComponent(format: codecType, depth: depth)
        // ProRes of 32 bits carries alpha, straight unless the entry says otherwise.
        if depth == 32 {
            format.containsAlphaChannel = format.containsAlphaChannel ?? true
            format.alphaChannelMode = format.alphaChannelMode ?? .straight
        }
    }

    // MARK: - Names

    /// Whether descriptions name the code point: those they don't name are left out of them.
    static func hasName(_ primaries: ColorPrimaries?) -> Bool {
        primaries.map { CVColorPrimariesGetStringForIntegerCodePoint(Int32($0.rawValue)) != nil } ?? false
    }

    static func hasName(_ transfer: TransferFunction?) -> Bool {
        transfer.map { CVTransferFunctionGetStringForIntegerCodePoint(Int32($0.rawValue)) != nil } ?? false
    }

    static func hasName(_ matrix: MatrixCoefficients?) -> Bool {
        matrix.map { CVYCbCrMatrixGetStringForIntegerCodePoint(Int32($0.rawValue)) != nil } ?? false
    }
}
