//
//  TsExtractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import OrderedCollections
import SEPlayerCommon

public final class TsExtractor: Extractor {
    public enum Mode {
        case multiPMT
        case singlePMT
        case hls
    }

    public struct Flags: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let emitRawSubtitleData = Flags(rawValue: 1)
    }

    private let queue: Queue
    private let extractorFlags: Flags
    private let timestampSearchBytes: Int
    private let state: State

    private var tsPacketBuffer: BlockBufferReader
    private var continuityCounters: OrderedDictionary<Int, Int>
    private let subtitleParserFactory: SubtitleParserFactory
    private let durationReader: TsDurationReader

    private var tsBinarySearchSeeker: TsBinarySearchSeeker?
    private var hasOutputSeekMap: Bool = false
    private var pendingSeekToStart: Bool = false
    private var bytesSinceLastSync: Int = 0

    /// - Parameter session: Maps sample times. In ``Mode/hls`` mode, segments of one discontinuity share it.
    public init(
        queue: Queue,
        mode: Mode = .singlePMT,
        extractorFlags: Flags = [],
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        session: TimestampAdjuster.Session? = nil,
        payloadReaderFactory: TsPayload.Factory = DefaultTsPayloadReaderFactory(),
        timestampSearchBytes: Int = TSConstants.timestampSearchBytes
    ) throws {
        self.queue = queue
        self.extractorFlags = extractorFlags
        self.subtitleParserFactory = subtitleParserFactory
        self.timestampSearchBytes = timestampSearchBytes

        let clockDomains = switch mode {
        case .multiPMT:
            ProgramClockDomains(
                perProgram: TimestampAdjuster(mode: .firstSampleAt(.zero))
            )
        case .singlePMT,
             .hls:
            ProgramClockDomains(
                unified: session ?? TimestampAdjuster(mode: .firstSampleAt(.zero)).makeSession()
            )
        }

        state = State(
            mode: mode,
            payloadReaderFactory: payloadReaderFactory,
            clockDomains: clockDomains
        )

        tsPacketBuffer = try BlockBufferReader()
        continuityCounters = .init()
        durationReader = .init(timestampSearchBytes: timestampSearchBytes)
        try resetPayloadReaders()
    }

    public func sniff(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> Bool {
        let buffer = try await BlockBufferReader(input.peekFully(
            length: TSConstants.packetSize * TSConstants.sniffPacketCount,
            isolation
        )).bytesView

        for startPosCandidate in 0 ..< TSConstants.packetSize {
            // Try to identify at least TSConstants.sniffPacketCount packets starting with TSConstants.syncByte.
            var isSyncBytePatternCorrect = true
            for i in 0 ..< TSConstants.sniffPacketCount {
                if buffer[startPosCandidate + i * TSConstants.packetSize] != TSConstants.syncByte {
                    isSyncBytePatternCorrect = false
                    break
                }
            }

            if isSyncBytePatternCorrect {
                try input.skip(length: startPosCandidate, isolation)
                return true
            }
        }

        return false
    }

    public func initialize(output: any ExtractorOutput, _ isolation: isolated any Actor) async throws {
        state.output = if extractorFlags.contains(.emitRawSubtitleData) {
            output
        } else {
            SubtitleTranscodingExtractorOutput(
                delegate: output,
                subtitleParserFactory: subtitleParserFactory
            )
        }
    }

    public func seek(to position: Int, time: CMTime, _ isolation: isolated any Actor) throws {
        assert(state.mode != .hls)
        for session in state.clockDomains.allSessions {
            // If the timestamp adjuster has not yet established a timestamp offset, we need to reset its
            // expected first sample timestamp to be the new seek position. Without this, the timestamp
            // adjuster would incorrectly establish its timestamp offset assuming that the first sample
            // after this seek corresponds to the start of the stream (or a previous seek position, if
            // there was one).
            var resetSession = !session.hasEstablishedOffset
            if !resetSession, let desired = session.desiredFirstSampleTime {
                // Also reset the timestamp adjuster if its offset was calculated based on a non-zero
                // position in the stream (other than the position being seeked to), since in this case the
                // offset may not be accurate.
                resetSession = desired.isNumeric && desired != .zero && desired != time
            }

            if resetSession {
                session.reset(desiredFirstSampleTime: time)
            }
        }

        if time != .zero, let tsBinarySearchSeeker {
            tsBinarySearchSeeker.setSeekTarget(time: time)
        }

        try tsPacketBuffer.clear()
        continuityCounters.removeAll()
        state.tsPayloadReaders.values.forEach { $0.seek() }
        bytesSinceLastSync = 0
    }

    public func read(input: any ExtractorInput, _ isolation: isolated any Actor) async throws -> ExtractorReadResult {
        let inputLength = input.getLength(isolation)
        let isModeHls = state.mode == .hls

        if state.tracksEnded {
            let canReadDuration = inputLength != nil && !isModeHls
            if canReadDuration, !durationReader.isDurationReadFinished {
                return try await durationReader.readDuration(
                    input: input,
                    pcrPid: state.pcrPid,
                    isolation
                )
            }

            maybeOutputSeekMap(inputLength: inputLength)

            if pendingSeekToStart {
                pendingSeekToStart = false
                try seek(to: .zero, time: .zero, isolation)

                if input.getPosition(isolation) != 0 {
                    return .seek(offset: .zero)
                }
            }

            if let tsBinarySearchSeeker, tsBinarySearchSeeker.isSeeking {
                return try await tsBinarySearchSeeker.handlePendingSeek(input: input, isolation)
            }
        }

        if try await !fillBufferWithAtLeastOnePacket(from: input, isolation) {
            // Send a synthesized empty pusi to allow for packetFinished to be triggered on the last unit.
            for payloadReader in state.tsPayloadReaders.values {
                if let pesReader = payloadReader as? PesReader,
                   try pesReader.canConsumeSynthesizedEmptyPusi(isModeHls: isModeHls) {
                    var empty = try BlockBufferReader()
                    try pesReader.consume(data: &empty, flags: .payloadUnitStart)
                }
            }

            return .endOfInput
        }

        let endOfPacket = try findEndOfFirstTsPacketInBuffer()
        let capacity = tsPacketBuffer.capacity
        if endOfPacket > capacity {
            return .continueRead
        }

        var packetHeaderFlags = TsPayload.PacketIndicators()
        // Note: See ISO/IEC 13818-1, section 2.4.3.2 for details of the header format.
        let tsPacketHeader = try Int(tsPacketBuffer.readInt(as: UInt32.self))
        if (tsPacketHeader & 0x800000) != 0 { // transport_error_indicator
            // There are uncorrectable errors in this packet.
            tsPacketBuffer.moveReaderIndex(to: endOfPacket)
            return .continueRead
        }

        if tsPacketHeader & 0x400000 != 0 {
            packetHeaderFlags.insert(.payloadUnitStart)
        }
        // Ignoring transport_priority (tsPacketHeader & 0x200000)
        let pid = (tsPacketHeader & 0x1FFF00) >> 8
        // Ignoring transport_scrambling_control (tsPacketHeader & 0xC0)
        let adaptationFieldExists = (tsPacketHeader & 0x20) != 0
        let payloadExists = (tsPacketHeader & 0x10) != 0

        guard let payloadReader = payloadExists ? state.tsPayloadReaders[pid] : nil else {
            tsPacketBuffer.moveReaderIndex(to: endOfPacket)
            return .continueRead
        }

        if !isModeHls {
            let continuityCounter = Int(tsPacketHeader & 0xF)
            let previousCounter = continuityCounters[pid] ?? (continuityCounter - 1)
            continuityCounters[pid] = continuityCounter

            if previousCounter == continuityCounter {
                // Duplicate packet found.
                tsPacketBuffer.moveReaderIndex(to: endOfPacket)
                return .continueRead
            } else if continuityCounter != ((previousCounter + 1) & 0xF) {
                // Discontinuity found.
                payloadReader.seek()
            }
        }

        // Skip the adaptation field.
        if adaptationFieldExists {
            let adaptationFieldLength = try Int(tsPacketBuffer.readInt(as: UInt8.self))
            let payloadStart = tsPacketBuffer.readerIndex + adaptationFieldLength
            guard payloadStart <= endOfPacket else {
                // The field can't be longer than the packet: the packet is damaged.
                tsPacketBuffer.moveReaderIndex(to: endOfPacket)
                return .continueRead
            }
            if adaptationFieldLength > 0 {
                let adaptationFieldFlags: UInt8 = try tsPacketBuffer.readInt()
                // random_access_indicator.
                if adaptationFieldFlags & 0x40 != 0 {
                    packetHeaderFlags.insert(.randomAccess)
                }
            }
            tsPacketBuffer.moveReaderIndex(to: payloadStart)
        }

        // Read the payload.
        let wereTracksEnded = state.tracksEnded
        if shouldConsumePacketPayload(packetPid: pid) {
            var packetBuffer = try tsPacketBuffer.readSlice(
                length: endOfPacket - tsPacketBuffer.readerIndex
            )

            try payloadReader.consume(
                data: &packetBuffer,
                flags: packetHeaderFlags
            )
        }

        if !isModeHls, !wereTracksEnded, state.tracksEnded, inputLength != nil {
            // We have read all tracks from all PMTs in this non-live stream. Now seek to the beginning
            // and read again to make sure we output all media, including any contained in packets prior
            // to those containing the track information.
            pendingSeekToStart = true
        }

        tsPacketBuffer.moveReaderIndex(to: endOfPacket)
        return .continueRead
    }

    private func maybeOutputSeekMap(inputLength: Int?) {
        guard !hasOutputSeekMap else { return }

        hasOutputSeekMap = true
        // The duration is only read when the length is known.
        if durationReader.getDuration().isNumeric, let inputLength {
            let tsBinarySearchSeeker = TsBinarySearchSeeker(
                streamDuration: durationReader.getDuration(),
                inputLength: inputLength,
                pcrPid: state.pcrPid,
                timestampSearchBytes: timestampSearchBytes
            )
            self.tsBinarySearchSeeker = tsBinarySearchSeeker
            SELogger.debug(.transportStream, "Seekable by binary search, \(durationReader.getDuration().seconds)s")
            state.output.seekMap(seekMap: tsBinarySearchSeeker.seekMap)
        } else {
            state.output.seekMap(seekMap: Unseekable(duration: durationReader.getDuration()))
        }
    }

    private func fillBufferWithAtLeastOnePacket(
        from input: any ExtractorInput,
        _ isolation: isolated any Actor
    ) async throws -> Bool {
        if tsPacketBuffer.readerIndex >= TSConstants.bufferSize {
            let bytesLeft = tsPacketBuffer.readableBytes
            if bytesLeft > 0 {
                tsPacketBuffer = try BlockBufferReader(
                    reader: tsPacketBuffer,
                    range: tsPacketBuffer.readerIndex ..< tsPacketBuffer.capacity,
                    permitEmptyReference: true
                )
            } else {
                try tsPacketBuffer.clear()
            }
        }

        while tsPacketBuffer.readableBytes < TSConstants.packetSize {
            let block = try await input.read(length: TSConstants.bufferSize, isolation)
            if block.dataLength == 0 {
                return false
            }
            try tsPacketBuffer.extend(with: block)
        }
        return true
    }

    private func findEndOfFirstTsPacketInBuffer() throws -> Int {
        let searchStart = tsPacketBuffer.readerIndex
        let limit = tsPacketBuffer.capacity
        let syncBytePosition = try TsUtil.findSyncBytePosition(
            tsPacketBuffer,
            startPosition: searchStart,
            limitPosition: limit
        )

        // Discard all bytes before the sync byte.
        // If sync byte is not found, this means discard the whole buffer.
        tsPacketBuffer.moveReaderIndex(to: syncBytePosition)
        let endOfPacket = syncBytePosition + TSConstants.packetSize
        if endOfPacket > limit {
            bytesSinceLastSync += syncBytePosition - searchStart
            if state.mode == .hls, bytesSinceLastSync > TSConstants.packetSize * 2 {
                throw ParserError.createForMalformedContainer(
                    message: "Cannot find sync byte. Most likely not a Transport Stream."
                )
            }
        } else {
            // We have found a packet within the buffer.
            bytesSinceLastSync = 0
        }

        return endOfPacket
    }

    private func shouldConsumePacketPayload(packetPid: Int) -> Bool {
        state.mode == .hls || state.tracksEnded || !state.trackPids.contains(packetPid) // It's a PSI packet
    }

    private func resetPayloadReaders() throws {
        state.trackIds.removeAll()
        state.tsPayloadReaders = try state.payloadReaderFactory.createInitialPayloadReaders()
        state.tsPayloadReaders[PatReader.patID] = try SectionReader(reader: PatReader(state: state))
        state.id3Reader = nil
    }
}

private extension TsExtractor {
    final class State {
        let mode: TsExtractor.Mode
        let payloadReaderFactory: TsPayload.Factory
        var clockDomains: ProgramClockDomains
        var tsPayloadReaders: OrderedDictionary<Int, TsPayload.Reader>
        var trackIds: Set<Int>
        var trackPids: Set<Int>
        var output: ExtractorOutput = PlaceholderExtractorOutput()
        var remainingPmts: Int = 0
        var tracksEnded: Bool = false
        var id3Reader: TsPayload.Reader?
        var pcrPid: Int = -1

        init(
            mode: TsExtractor.Mode,
            payloadReaderFactory: TsPayload.Factory,
            clockDomains: ProgramClockDomains
        ) {
            self.mode = mode
            self.payloadReaderFactory = payloadReaderFactory
            self.clockDomains = clockDomains
            self.tsPayloadReaders = .init()
            self.trackIds = .init()
            self.trackPids = .init()
        }
    }
}

private extension TsExtractor {
    final class PatReader: SectionPayloadReader {
        static let patID = 0

        /// Unowned: the state holds the reader among its payload readers, and outlives it.
        private unowned let state: TsExtractor.State

        init(state: TsExtractor.State) {
            self.state = state
        }

        func initialize(
            session: TimestampAdjuster.Session,
            extractorOutput: any ExtractorOutput,
            idGenerator: TsPayload.TrackIdGenerator
        ) throws {
            // Do nothing
        }

        func consume(sectionData: inout BlockBufferReader) throws {
            let tableId = try sectionData.readInt(as: UInt8.self)
            if tableId != 0x00 { // program_association_section
                // See ISO/IEC 13818-1, section 2.4.4.4 for more information on table id assignment.
                return
            }
            // section_syntax_indicator(1), '0'(1), reserved(2), section_length(4)
            let secondHeaderByte = try sectionData.readInt(as: UInt8.self)
            if (secondHeaderByte & 0x80) == 0 {
                // section_syntax_indicator must be 1. See ISO/IEC 13818-1, section 2.4.4.5.
                return
            }
            // section_length(8), transport_stream_id (16), reserved (2), version_number (5),
            // current_next_indicator (1), section_number (8), last_section_number (8)
            sectionData.moveReaderIndex(forwardBy: 6)

            let programCount = sectionData.readableBytes / 4
            for _ in 0 ..< programCount {
                var patScratch = try BlockBufferBitReader(reader: sectionData.readSlice(length: 4))
                let programNumber = try patScratch.readBits(16)
                patScratch.skipBits(3) // reserved (3)

                if programNumber == 0 {
                    patScratch.skipBits(13) // network_PID (13)
                } else {
                    let pid = try patScratch.readBits(13)
                    if state.tsPayloadReaders[pid] == nil {
                        state.tsPayloadReaders[pid] = try SectionReader(
                            reader: PmtReader(pid: pid, state: state)
                        )
                        state.remainingPmts += 1
                    }
                }
            }

            if state.mode != .hls {
                state.tsPayloadReaders.removeValue(forKey: PatReader.patID)
            }
        }
    }
}

private final class PmtReader: SectionPayloadReader {
    enum Descriptor: UInt8 {
        case registration = 0x05
        case iso639Lang = 0x0A
        case ac3 = 0x6A
        case ait = 0x6F
        case eac3 = 0x7A
        case dts = 0x7B
        case dvbExt = 0x7F
        case dvbSubs = 0x59
    }

    enum DVBDescriptorExtension: UInt8 {
        case dvbExtAc4 = 0x15
        case dvbExtDtsHd = 0x0E
        case dvbExtDtsUhd = 0x21
    }

    enum FormatIdentifiers: UInt32 {
        case AC3 = 0x41432d33
        case EAC3 = 0x45414333
        case AC4 = 0x41432d34
        case hevc = 0x48455643
    }

    private let pid: Int
    /// Unowned: the state holds the reader among its payload readers, and outlives it.
    private unowned let state: TsExtractor.State
    private var trackIdToReaderScratch: OrderedDictionary<Int, TsPayload.Reader>
    private var trackIdToPidScratch: OrderedDictionary<Int, Int>

    init(pid: Int, state: TsExtractor.State) {
        self.pid = pid
        self.state = state
        trackIdToReaderScratch = .init()
        trackIdToPidScratch = .init()
    }

    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        // Do nothing.
    }

    func consume(sectionData: inout BlockBufferReader) throws {
        let tableId = try sectionData.readInt(as: UInt8.self)
        if tableId != 0x02 { // TS_program_map_section
            // See ISO/IEC 13818-1, section 2.4.4.4 for more information on table id assignment.
            return
        }

        // section_syntax_indicator(1), '0'(1), reserved(2), section_length(4)
        let secondHeaderByte = try sectionData.readInt(as: UInt8.self)
        if (secondHeaderByte & 0x80) == 0 {
            // section_syntax_indicator must be 1. See ISO/IEC 13818-1, section 2.4.4.9.
            return
        }

        // section_length(8)
        sectionData.moveReaderIndex(forwardBy: 1)
        let programNumber = try sectionData.readInt(as: UInt16.self)

        let session = state.clockDomains.session(forProgram: Int(programNumber))

        // Skip 3 bytes (24 bits), including:
        // reserved (2), version_number (5), current_next_indicator (1), section_number (8),
        // last_section_number (8)
        sectionData.moveReaderIndex(forwardBy: 3)

        var pmtScratch = try BlockBufferBitReader(reader: sectionData.readSlice(length: 2))
        // reserved (3), PCR_PID (13)
        pmtScratch.skipBits(3)
        state.pcrPid = try pmtScratch.readBits(13)

        // Read program_info_length.
        pmtScratch = try BlockBufferBitReader(reader: sectionData.readSlice(length: 2))
        pmtScratch.skipBits(4)
        let programInfoLength = try pmtScratch.readBits(12)

        // Skip the descriptors.
        guard programInfoLength <= sectionData.readableBytes else {
            throw ParserError.createForMalformedContainer(message: "The program info is longer than its section.")
        }
        sectionData.moveReaderIndex(forwardBy: programInfoLength)

        if state.mode == .hls, state.id3Reader == nil {
            // Setup an ID3 track regardless of whether there's a corresponding entry, in case one
            // appears intermittently during playback.
            let id3EsInfo = TsPayload.ESInfo(
                streamType: .id3,
                language: nil,
                audioType: .undefined,
                dvbSubtitleInfos: nil,
                descriptorBytes: Data()
            )

            state.id3Reader = try state
                .payloadReaderFactory
                .createPayloadReader(streamType: TSStreamType.id3, esInfo: id3EsInfo)

            try state.id3Reader?.initialize(
                session: session,
                extractorOutput: state.output,
                idGenerator: .init(
                    programNumber: Int(programNumber),
                    firstTrackId: TSStreamType.id3.rawValue,
                    trackIdIncrement: TSConstants.maxPidPlusOne
                )
            )
        }

        trackIdToReaderScratch.removeAll()
        trackIdToPidScratch.removeAll()
        var remainingEntriesLength = sectionData.readableBytes

        while remainingEntriesLength > 0 {
            var entryScratch = try BlockBufferBitReader(reader: sectionData.readSlice(length: 5))
            var streamType = try entryScratch.readBits(8)
            entryScratch.skipBits(3) // reserved
            let elementaryPid = try entryScratch.readBits(13)
            entryScratch.skipBits(4) // reserved
            let esInfoLength = try entryScratch.readBits(12) // ES_info_length.
            let esInfo = try readEsInfo(&sectionData, length: esInfoLength)

            if streamType == 0x06 || streamType == 0x05 {
                streamType = esInfo.streamType?.rawValue ?? -1
            }
            remainingEntriesLength -= esInfoLength + 5

            let trackId = state.mode == .hls ? streamType : elementaryPid
            if state.trackIds.contains(trackId) { continue }

            let reader: TsPayload.Reader? = if state.mode == .hls, streamType == TSStreamType.id3.rawValue {
                state.id3Reader
            } else {
                try state.payloadReaderFactory
                    .createPayloadReader(streamType: .init(rawValue: streamType), esInfo: esInfo)
            }
            let readerName = reader.map { "\(type(of: $0))" } ?? "not read"
            SELogger.debug(
                .transportStream,
                "PMT stream type 0x\(String(streamType, radix: 16)) on PID \(elementaryPid): \(readerName)"
            )

            if state.mode != .hls
                || elementaryPid < (trackIdToPidScratch[trackId] ?? TSConstants.maxPidPlusOne) {
                trackIdToPidScratch[trackId] = elementaryPid
                trackIdToReaderScratch[trackId] = reader
            }
        }

        for trackId in trackIdToPidScratch.keys {
            guard let trackPid = trackIdToPidScratch[trackId] else { continue }
            state.trackIds.insert(trackId)
            state.trackPids.insert(trackPid)

            guard let reader = trackIdToReaderScratch[trackId] ?? nil else {
                continue
            }
            if reader !== state.id3Reader {
                try reader.initialize(
                    session: session,
                    extractorOutput: state.output,
                    idGenerator: TsPayload.TrackIdGenerator(
                        programNumber: Int(programNumber),
                        firstTrackId: trackId,
                        trackIdIncrement: TSConstants.maxPidPlusOne
                    )
                )
            }
            state.tsPayloadReaders[trackPid] = reader
        }

        if state.mode == .hls {
            if !state.tracksEnded {
                SELogger.info(
                    .transportStream,
                    "Tracks of program \(programNumber): \(state.tsPayloadReaders.count) readers"
                )
                state.output.endTracks()
                state.remainingPmts = 0
                state.tracksEnded = true
            }
        } else {
            state.tsPayloadReaders.removeValue(forKey: pid)
            state.remainingPmts = state.mode == .singlePMT ? 0 : state.remainingPmts - 1
            if state.remainingPmts == 0 {
                SELogger.info(.transportStream, "Tracks of all programs: \(state.tsPayloadReaders.count) readers")
                state.output.endTracks()
                state.tracksEnded = true
            }
        }
    }

    private func readEsInfo(_ data: inout BlockBufferReader, length: Int) throws -> TsPayload.ESInfo {
        let descriptorsStartPosition = data.readerIndex
        let descriptorsEndPosition = descriptorsStartPosition + length
        guard descriptorsEndPosition <= data.capacity else {
            throw ParserError.createForMalformedContainer(message: "The descriptors are longer than their section.")
        }
        var streamType: TSStreamType?
        var language: String?
        var audioType: TsPayload.ESInfo.AudioType = .undefined
        var dvbSubtitleInfos: [TsPayload.DvbSubtitleInfo]?

        while data.readerIndex < descriptorsEndPosition {
            let descriptorTag = try Descriptor(rawValue: data.readInt(as: UInt8.self))
            let descriptorLength = try data.readInt(as: UInt8.self)
            let positionOfNextDescriptor = data.readerIndex + Int(descriptorLength)
            if positionOfNextDescriptor > descriptorsEndPosition {
                // Descriptor claims to extend past the end position. Skip it.
                break
            }

            switch descriptorTag {
            case .registration:
                if let formatIdentifier = try FormatIdentifiers(rawValue: data.readInt()) {
                    switch formatIdentifier {
                    case .AC3:
                        streamType = .ac3
                    case .EAC3:
                        streamType = .eAc3
                    case .AC4:
                        streamType = .ac4
                    case .hevc:
                        streamType = .h265
                    }
                }
            case .ac3: // AC-3_descriptor in DVB (ETSI EN 300 468)
                streamType = .ac3
            case .eac3: // enhanced_AC-3_descriptor
                streamType = .eAc3
            case .dvbExt:
                // Extension descriptor in DVB (ETSI EN 300 468).
                if let descriptorTagExt = try DVBDescriptorExtension(rawValue: data.readInt()) {
                    switch descriptorTagExt {
                    case .dvbExtAc4:
                        // AC-4_descriptor in DVB (ETSI EN 300 468).
                        streamType = .ac4
                    case .dvbExtDtsHd:
                        streamType = .dtsHD
                    case .dvbExtDtsUhd:
                        streamType = .dtsUHD
                    }
                }
            case .dts: // DTS_descriptor
                streamType = .dts
            case .iso639Lang:
                language = data.readString(length: 3, encoding: .utf8)
                audioType = try .init(rawValue: data.readInt()) ?? .undefined
            case .dvbSubs:
                streamType = .dvbSubs
                dvbSubtitleInfos = [TsPayload.DvbSubtitleInfo]()
                while data.readerIndex < positionOfNextDescriptor {
                    let dvbLanguage = data.readString(length: 3, encoding: .utf8)
                    let dvbSubtitlingType = try data.readInt(as: UInt8.self)
                    let compositionPageID = try Int(data.readInt(as: UInt16.self))
                    let ancillaryPageID = try Int(data.readInt(as: UInt16.self))
                    dvbSubtitleInfos?.append(.init(
                        language: dvbLanguage,
                        type: Int(dvbSubtitlingType),
                        compositionPageID: compositionPageID,
                        ancillaryPageID: ancillaryPageID
                    ))
                }
            case .ait:
                streamType = .ait
            case .none:
                break
            }

            data.moveReaderIndex(forwardBy: positionOfNextDescriptor - data.readerIndex)
        }

        data.moveReaderIndex(to: descriptorsEndPosition)

        let descriptorBytes = Data(data.bytesView[descriptorsStartPosition ..< descriptorsEndPosition])

        return TsPayload.ESInfo(
            streamType: streamType,
            language: language,
            audioType: audioType,
            dvbSubtitleInfos: dvbSubtitleInfos,
            descriptorBytes: descriptorBytes
        )
    }
}
