//
//  DefaultTsPayloadReaderFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import OrderedCollections
import SEPlayerCommon

public final class DefaultTsPayloadReaderFactory: TsPayload.Factory {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// When extracting H.264 samples, whether to treat samples consisting of non-IDR I slices
        /// as synchronization samples (key-frames).
        public static let allowNonIDRKeyframes = Flags(rawValue: 1 << 0)

        /// Prevents the creation of `AdtsReader` and `LatmReader` instances. Enable this if the
        /// transport stream contains no packets for an AAC elementary stream declared in the PMT.
        public static let ignoreAACStream = Flags(rawValue: 1 << 1)

        /// Prevents the creation of `H264Reader` instances. Enable this if the transport stream
        /// contains no packets for an H.264 elementary stream declared in the PMT.
        public static let ignoreH264Stream = Flags(rawValue: 1 << 2)

        /// When extracting H.264 samples, whether to split the input stream into access units
        /// (samples) based on slice headers. Disable this if the stream contains access unit
        /// delimiters (AUDs).
        public static let detectAccessUnits = Flags(rawValue: 1 << 3)

        /// Prevents the creation of `SectionPayloadReader`s for splice information sections (SCTE-35).
        public static let ignoreSpliceInfoStream = Flags(rawValue: 1 << 4)

        /// Whether the supplied list of closed caption formats should be used in spite of any closed
        /// captions service descriptors. If disabled, the formats are ignored when the PMT contains
        /// closed captions service descriptors.
        public static let overrideCaptionDescriptors = Flags(rawValue: 1 << 5)

        /// Whether HDMV DTS audio streams will be handled. If set, SCTE subtitles will not be
        /// detected, as they share the same elementary stream type as HDMV DTS.
        public static let enableHDMVDTSAudioStreams = Flags(rawValue: 1 << 6)
    }

    private let flags: Flags
    private let closedCaptionFormats: [TextFormat]

    public init(flags: Flags = [], closedCaptionFormats: [TextFormat] = []) {
        self.flags = flags
        self.closedCaptionFormats = closedCaptionFormats
    }

    public func createInitialPayloadReaders() throws -> OrderedDictionary<Int, any TsPayload.Reader> { [:] }

    public func createPayloadReader(streamType: TSStreamType?, esInfo: TsPayload.ESInfo) throws -> (any TsPayload.Reader)? {
        let language = esInfo.language
        let roleFlags = esInfo.audioType.roleFlags
        switch streamType {
        case .mpa,
             .mpaLsf:
            return try PesReader(
                reader: MpegAudioReader(language: language, roleFlags: roleFlags, containerMimeType: .videoMP2T)
            )
        case .aacAdts:
            guard !flags.contains(.ignoreAACStream) else { return nil }
            return try PesReader(
                reader: AdtsReader(
                    exposeId3: false,
                    language: language,
                    roleFlags: roleFlags,
                    containerMimeType: .videoMP2T
                )
            )
        case .aacLatm:
            guard !flags.contains(.ignoreAACStream) else { return nil }
            return try PesReader(
                reader: LatmReader(language: language, roleFlags: roleFlags, containerMimeType: .videoMP2T)
            )
        case .ac3,
             .eAc3:
            return try PesReader(
                reader: Ac3Reader(language: language, roleFlags: roleFlags, containerMimeType: .videoMP2T)
            )
        case .ac4:
            return try PesReader(
                reader: Ac4Reader(language: language, roleFlags: roleFlags, containerMimeType: .videoMP2T)
            )
        case .hdmvDts where !flags.contains(.enableHDMVDTSAudioStreams):
            return nil
        case .hdmvDts,
             .dts,
             .dtsHD,
             .dtsUHD:
            return try PesReader(
                reader: DtsReader(language: language, roleFlags: roleFlags, containerMimeType: .videoMP2T)
            )
        case .h262,
             .dc2H262:
            return try PesReader(
                reader: H262Reader(userDataReader: buildUserDataReader(with: esInfo), containerMimeType: .videoMP2T)
            )
        case .h263:
            return try PesReader(
                reader: H263Reader(userDataReader: buildUserDataReader(with: esInfo), containerMimeType: .videoMP2T)
            )
        case .h264,
             .h264Encrypted:
            guard !flags.contains(.ignoreH264Stream) else { return nil }

            return try PesReader(
                reader: H264Reader(
                    seiReader: buildSeiReader(with: esInfo),
                    allowNonIdrKeyframes: flags.contains(.allowNonIDRKeyframes),
                    detectAccessUnits: flags.contains(.detectAccessUnits),
                    containerMimeType: .videoMP2T
                )
            )
        case .h265:
            return try PesReader(
                reader: H265Reader(seiReader: buildSeiReader(with: esInfo), containerMimeType: .videoMP2T)
            )
        case .spliceInfo:
            guard !flags.contains(.ignoreSpliceInfoStream) else { return nil }
            return try SectionReader(
                reader: PassthroughSectionPayloadReader(sampleMimeType: .applicationSCTE35, containerMimeType: .videoMP2T)
            )
        case .id3:
            return try PesReader(reader: Id3Reader(containerMimeType: .videoMP2T))
        case .dvbSubs:
            return try PesReader(reader: DvbSubtitleReader(subtitleInfos: esInfo.dvbSubtitleInfos))
        case .ait:
            return try SectionReader(
                reader: PassthroughSectionPayloadReader(sampleMimeType: .applicationAIT, containerMimeType: .videoMP2T)
            )
        case .mhas:
            return try PesReader(reader: MpeghReader(containerMimeType: .videoMP2T))
        case .none:
            return nil
        }
    }

    private func buildUserDataReader(with esInfo: TsPayload.ESInfo) throws -> UserDataReader {
        try UserDataReader(closedCaptionFormats: getClosedCaptionFormats(from: esInfo), containerMimeType: .videoMP2T)
    }

    private func buildSeiReader(with esInfo: TsPayload.ESInfo) -> SeiReader {
        SeiReader(
            closedCaptionFormats: getClosedCaptionFormats(from: esInfo),
            containerMimeType: .videoMP2T
        )
    }

    /// The closed captions of a video stream: those given, unless its caption service descriptor (ATSC A/65) says
    /// which there are.
    private func getClosedCaptionFormats(from esInfo: TsPayload.ESInfo) -> [TextFormat] {
        guard !flags.contains(.overrideCaptionDescriptors) else {
            return closedCaptionFormats
        }

        var formats = closedCaptionFormats
        var data = Array(esInfo.descriptorBytes)[...]
        while data.count >= 2 {
            let tag = data.removeFirst()
            let length = Int(data.removeFirst())
            guard data.count >= length else { break }
            var descriptor = data.prefix(length)
            data = data.dropFirst(length)
            guard tag == Self.captionServiceDescriptorTag, let header = descriptor.popFirst() else {
                continue
            }

            formats = []
            let serviceCount = Int(header & 0x1F)
            for _ in 0 ..< serviceCount {
                guard descriptor.count >= 6 else { break }
                let language = String(bytes: descriptor.prefix(3), encoding: .ascii)
                descriptor = descriptor.dropFirst(3)
                let captionType = descriptor.removeFirst()
                let isDigital = captionType & 0x80 != 0
                descriptor = descriptor.dropFirst(2) // easy_reader, wide_aspect_ratio, reserved
                let codec = if isDigital {
                    TextCodec(.applicationCEA708, \.cea708) { $0.serviceNumber = Int(captionType & 0x3F) }
                } else {
                    TextCodec(.applicationCEA608, \.cea608) { $0.channel = 1 }
                }
                formats.append(TextFormat {
                    $0.codec = codec
                    $0.language = language
                })
            }
            SELogger.debug(.transportStream, "Caption service descriptor: \(formats.count) services")
        }
        return formats
    }

    private static let captionServiceDescriptorTag: UInt8 = 0x86
}
