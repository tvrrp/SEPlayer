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
    private let closedCaptionFormats: [Format]

    public init(flags: Flags = [], closedCaptionFormats: [Format] = []) {
        self.flags = flags
        self.closedCaptionFormats = closedCaptionFormats
    }

    public func createInitialPayloadReaders() throws -> OrderedDictionary<Int, any TsPayload.Reader> { [:] }

    public func createPayloadReader(streamType: TSStreamType?, esInfo: TsPayload.ESInfo) throws -> (any TsPayload.Reader)? {
        switch streamType {
        case .aacAdts:
            guard !flags.contains(.ignoreAACStream) else { return nil }

            return try PesReader(
                reader: AdtsReader(
                    exposeId3: false,
                    language: esInfo.language,
                    roleFlags: esInfo.audioType.roleFlags,
                    containerMimeType: .videoMP2T
                )
            )
        case .h264, .h264Encrypted:
            guard !flags.contains(.ignoreAACStream) else { return nil }

            return try PesReader(
                reader: H264Reader(
                    seiReader: buildSeiReader(with: esInfo),
                    allowNonIdrKeyframes: flags.contains(.allowNonIDRKeyframes),
                    detectAccessUnits: flags.contains(.detectAccessUnits),
                    containerMimeType: .videoMP2T
                )
            )
        case .none:
            return nil
        default:
            // TODO: remove default
            return nil
        }
    }

    private func buildSeiReader(with esInfo: TsPayload.ESInfo) -> SeiReader {
        SeiReader(
            closedCaptionFormats: getClosedCaptionFormats(from: esInfo),
            containerMimeType: .videoMP2T
        )
    }

    private func getClosedCaptionFormats(from esInfo: TsPayload.ESInfo) -> [Format] {
        return []
//        fatalError()
    }
}
