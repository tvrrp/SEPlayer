//
//  VideoFormat+FormatDescription.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import SEPlayerCommon

extension Format where Scope == FormatAttributes.Video {
    /// The format of a format description the system made: what it holds, with what that tells in our types.
    init(formatDescription description: CMFormatDescription) throws {
        try self.init(copying: description)
        let boxes = self.boxes
        try readCodec { type in
            boxes.payload(of: FourCharacterCode(type)).flatMap { try? BlockBufferReader(bytes: $0) }
        }
    }

    /// The format of a stream that carries its parameter sets, as a sample entry with their configuration record
    /// alone describes it.
    ///
    /// - Parameters:
    ///   - width: The width of the pictures, as the parameter sets tell it.
    ///   - record: The configuration record of the parameter sets, such as an `avcC`.
    init(
        codecType: FourCharCode,
        width: Int,
        height: Int,
        configurationRecord record: Data,
        flavor: VideoSampleEntryUtil.ParameterSetFlavor
    ) throws {
        self.init()
        self.size = VideoSize(width: width, height: height)
        try replaceConfigurationRecord(with: record, codecType: codecType, flavor: flavor)
    }

    /// Puts the configuration record of parameter sets the samples carried in place of the one the format has, such
    /// as an empty one of an `avc3` sample entry.
    ///
    /// What the parameter sets tell joins the attributes where the format has none, and the sample entry, which the
    /// record no longer matches, is left out.
    mutating func replaceConfigurationRecord(
        with record: Data,
        codecType: FourCharCode,
        flavor: VideoSampleEntryUtil.ParameterSetFlavor
    ) throws {
        let configType = FourCharacterCode(flavor.configType)
        let recordReader = try BlockBufferReader(bytes: record)
        self.sampleEntry = nil
        var boxes = self.boxes.filter { $0.type != configType }
        boxes.insert(MediaBox(type: configType, payload: record), at: 0)
        self.boxes = boxes
        self.codecType = FourCharacterCode(codecType)
        _ = VideoSampleEntryUtil.addParameterSetAttributes(to: &self, config: recordReader, flavor: flavor)
        try readCodec { type in
            guard type != flavor.configType else { return recordReader }
            return boxes.payload(of: FourCharacterCode(type)).flatMap { try? BlockBufferReader(bytes: $0) }
        }
    }

    /// Reads the codec of the codec type and its configuration boxes, the ratio of the pixels into the size, and the
    /// bitrates of a `btrt` box.
    ///
    /// - Parameter configuration: The payload of the box of a type the sample entry has, such as `avcC`.
    mutating func readCodec(configuration: (MP4Box.BoxType) -> BlockBufferReader?) throws {
        let codecType = try self.codecType.checkNotNil(FormatConversionError.missingAttribute("codecType"))
        self.codec = try Self.codec(codecType: codecType.rawValue, configuration: configuration)
        if let ratio = self.pixelAspectRatio, ratio.horizontalSpacing > 0, ratio.verticalSpacing > 0, let size = self.size {
            self.size = VideoSize(width: size.width, height: size.height, pixelWidthHeightRatio: ratio.ratio)
        }
        if let bitrates = configuration(.btrt) {
            try setBitrates(btrt: bitrates)
        }
    }

    /// The codec of a codec type, with the attributes of its configuration boxes.
    private static func codec(
        codecType: FourCharCode,
        configuration: (MP4Box.BoxType) -> BlockBufferReader?
    ) throws -> VideoCodec {
        guard let type = MP4Box.BoxType(rawValue: codecType) else {
            throw FormatConversionError.unsupportedCodec(nil)
        }
        switch type {
        case .avc1,
             .avc3,
             .cavc,
             .qavc,
             .qave:
            return try .h264 { h264 in
                if let avcC = configuration(.avcC) {
                    h264 = try CodecAttributes(avcC: avcC)
                }
                h264.hasInBandParameterSets = type == .avc3
            }
        case .hvc1,
             .hev1,
             .chvc,
             .qhvc,
             .qhev,
             .muxa:
            var codec = try VideoCodec.hevc { hevc in
                if let hvcC = configuration(.hvcC) {
                    hevc = try CodecAttributes(hvcC: hvcC)
                }
                hevc.hasInBandParameterSets = type == .hev1
            }
            // A Dolby Vision layer that HEVC decoders may leave aside, as in profile 8.
            if let record = configuration(.dvcC) ?? configuration(.dvvC) ?? configuration(.dvwC) {
                codec.dolbyVision = try CodecAttributes(dvcC: record)
                codec.dolbyVision.baseLayer = .videoH265
            }
            return codec
        case .dvh1,
             .dvhe,
             .cdh1,
             .qdh1,
             .qdhe,
             .dvav,
             .dva1,
             .dav1,
             .qdav:
            return try dolbyVisionCodec(type: type, configuration: configuration)
        case .av01,
             .qav1:
            return try .av1 { av1 in
                if let av1C = configuration(.av1C) {
                    av1 = try CodecAttributes(av1C: av1C)
                }
            }
        case .vp08,
             .vp09,
             .qvp9:
            var codec = VideoCodec(type == .vp08 ? .videoVP8 : .videoVP9)
            if let vpcC = configuration(.vpcC) {
                codec.vp9 = try CodecAttributes(vpcC: vpcC)
            }
            return codec
        case .mp4v:
            var codec = VideoCodec(.videoMP4V)
            let headers = configuration(.esds)
                .flatMap { try? $0.slice(from: $0.readerIndex + 4) }
                .flatMap { ElementaryStreamDescriptor(esds: $0) }?
                .decoderSpecificInfo
            if let headers {
                codec.mpeg4Visual = try CodecAttributes(decoderSpecificInfo: headers)
            }
            return codec
        case .h263,
             .s263,
             .H263:
            var codec = VideoCodec(.videoH263)
            if let d263 = configuration(.d263) {
                codec.h263 = try CodecAttributes(d263: d263)
            }
            return codec
        case .mp1v,
             .m1v_:
            return VideoCodec(.videoMPEG)
        case .mp2v:
            return VideoCodec(.videoMPEG2)
        case .jpeg,
             .mjpg:
            return VideoCodec(.videoMJPEG)
        default:
            if MpegVideoUtil.mpeg2ProfileFormats.contains(type) {
                return VideoCodec(.videoMPEG2)
            }
            if let variant = VideoCodec.ProRes.Variant(sampleEntryType: type) {
                return VideoCodec(.videoProRes, \.proRes) { $0.variant = variant }
            }
            throw FormatConversionError.unsupportedCodec(nil)
        }
    }

    /// Dolby Vision, with the attributes of its base layer.
    private static func dolbyVisionCodec(
        type: MP4Box.BoxType,
        configuration: (MP4Box.BoxType) -> BlockBufferReader?
    ) throws -> VideoCodec {
        let baseLayer: MimeTypes = switch type {
        case .dvav,
             .dva1: .videoH264
        case .dav1,
             .qdav: .videoAV1
        default: .videoH265
        }
        let record = configuration(.dvcC) ?? configuration(.dvvC) ?? configuration(.dvwC)

        var codec = try VideoCodec.dolbyVision { dolbyVision in
            if let record {
                dolbyVision = try CodecAttributes(dvcC: record)
            }
            dolbyVision.baseLayer = baseLayer
        }
        if let avcC = configuration(.avcC) {
            codec.h264 = try CodecAttributes(avcC: avcC)
        }
        if let hvcC = configuration(.hvcC) {
            codec.hevc = try CodecAttributes(hvcC: hvcC)
        }
        if let av1C = configuration(.av1C) {
            codec.av1 = try CodecAttributes(av1C: av1C)
        }
        return codec
    }

    /// Takes the bitrates of a `btrt` box: the size of the decoding buffer, then the peak and the average bitrate.
    private mutating func setBitrates(btrt box: BlockBufferReader) throws {
        var reader = box
        reader.moveReaderIndex(forwardBy: 4)
        let peakBitrate = try Int(reader.readInt(as: UInt32.self))
        let averageBitrate = try Int(reader.readInt(as: UInt32.self))
        // Writers leave 0 for a bitrate they don't know.
        self.peakBitrate = peakBitrate > 0 ? peakBitrate : nil
        self.averageBitrate = averageBitrate > 0 ? averageBitrate : nil
    }
}
