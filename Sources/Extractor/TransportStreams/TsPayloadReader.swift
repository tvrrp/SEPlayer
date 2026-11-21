//
//  TsPayloadReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import Foundation
import OrderedCollections
import SEPlayerCommon

public enum TsPayload {
    public protocol Factory {
        func createInitialPayloadReaders() throws -> OrderedDictionary<Int, TsPayload.Reader>
        func createPayloadReader(streamType: TSStreamType?, esInfo: ESInfo) throws -> TsPayload.Reader?
    }

    public struct ESInfo {
        public enum AudioType: UInt8 {
            case undefined = 0
            case cleanEffects = 1
            case hearingImpaired = 2
            case visualImpairedCommentary = 3

            public var roleFlags: RoleFlags {
                switch self {
                case .hearingImpaired:
                    .enhancedDialogIntelligibility
                case .visualImpairedCommentary:
                    .describesVideo
                default:
                    []
                }
            }
        }

        public let streamType: TSStreamType?
        public let language: String?
        public let audioType: AudioType
        public let dvbSubtitleInfos: [DvbSubtitleInfo]
        public let descriptorBytes: Data

        public init(
            streamType: TSStreamType?,
            language: String?,
            audioType: AudioType,
            dvbSubtitleInfos: [DvbSubtitleInfo]?,
            descriptorBytes: Data
        ) {
            self.streamType = streamType
            self.language = language
            self.audioType = audioType
            self.dvbSubtitleInfos = dvbSubtitleInfos ?? []
            self.descriptorBytes = descriptorBytes
        }
    }

    public struct DvbSubtitleInfo {
        public let language: String?
        public let type: Int
        public let compositionPageID: Int
        public let ancillaryPageID: Int
    }

    public final class TrackIdGenerator {
        private let formatIdPrefix: String
        private let firstTrackId: Int
        private let trackIdIncrement: Int
        private var trackId: Int?
        private var formatId: String

        public init(
            programNumber: Int? = nil,
            firstTrackId: Int,
            trackIdIncrement: Int
        ) {
            formatIdPrefix = if let programNumber { "\(programNumber)/" } else { "" }
            self.firstTrackId = firstTrackId
            self.trackIdIncrement = trackIdIncrement
            formatId = ""
        }

        public func generateNewId() {
            let trackId = if let trackId { trackId + trackIdIncrement } else { firstTrackId }
            self.trackId = trackId
            formatId = formatIdPrefix + "\(trackId)"
        }

        public func getTrackId() throws -> Int {
            try trackId.checkNotNil()
        }

        public func getFormatId() throws -> String {
            try trackId.checkNotNil()
            return formatId
        }
    }

    public struct PacketIndicators: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Indicates the presence of the payload_unit_start_indicator in the TS packet header.
        public static let payloadUnitStart = Self(rawValue: 1)
        /// Indicates the presence of the random_access_indicator in the TS packet header adaptation field.
        public static let randomAccess = Self(rawValue: 1 << 1)
        /// Indicates the presence of the data_alignment_indicator in the PES header.
        public static let dataAlignment = Self(rawValue: 1 << 2)
    }

    public protocol Reader: AnyObject {
        func initialize(
            session: TimestampAdjuster.Session,
            extractorOutput: ExtractorOutput,
            idGenerator: TrackIdGenerator
        ) throws
        func seek()
        func consume(
            data: inout BlockBufferReader,
            flags: TsPayload.PacketIndicators
        ) throws
    }
}
