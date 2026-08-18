//
//  PesReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//

import CoreMedia
import SEPlayerCommon

/// Parses PES packet data and extracts samples.
final class PesReader: TsPayload.Reader {
    enum State {
        case findingHeader
        case readingHeader
        case readingHeaderExtension
        case readingBody
    }

    private let reader: ElementaryStreamReader
    private var pesScratch: BlockBufferBitReader
    private var timestampAdjuster: TimestampAdjuster.Session?

    private var state: State
    private var bytesRead = 0

    private var ptsFlag = false
    private var dtsFlag = false
    private var extendedHeaderLength = 0
    private var payloadSize: Int?
    private var dataAlignmentIndicator = false
    private var dts: CMTime = .zero
    private var pts: CMTime = .zero

    init(reader: any ElementaryStreamReader) throws {
        self.reader = reader
        pesScratch = try BlockBufferBitReader(
            CMBlockBuffer(length: .pesScratchSize)
        )
        state = .findingHeader
        bytesRead = .zero
    }

    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator,
        _ isolation: isolated any Actor
    ) async throws {
        self.timestampAdjuster = session
        try await reader.createTracks(
            output: extractorOutput,
            idGenerator: idGenerator,
            isolation
        )
    }

    func seek() {
        state = .findingHeader
        bytesRead = 0
        reader.seek()
    }

    func consume(
        data: inout BlockBufferReader,
        flags: TsPayload.PacketIndicators,
        _ isolation: isolated any Actor
    ) async throws {
        let timestampAdjuster = try timestampAdjuster.checkNotNil()

        if flags.contains(.payloadUnitStart) {
            switch state {
            case .findingHeader, .readingHeader:
                // Expected.
                break
            case .readingHeaderExtension:
                // TODO: log Unexpected start indicator reading extended header
                break
            case .readingBody:
                // If payloadSize is unset then the length of the previous packet was unspecified, and so
                // we only know that it's finished now that we've seen the start of the next one. This is
                // expected. If payloadSize is set, then the length of the previous packet was known, but
                // we didn't receive that amount of data. This is not expected.
                if payloadSize != nil {
                    // TODO: log "Unexpected start indicator: expected \(payloadSize) more bytes");
                }

                // Either way, notify the reader that it has now finished.
                try await reader.packetFinished(isolation)
            }

            if data.readableBytes == 0 {
                try await reader.endOfInputReached(isolation)
            }

            setState(.readingHeader)
        }

        while data.readableBytes > 0 {
            switch state {
            case .findingHeader:
                data.moveReaderIndex(forwardBy: data.readableBytes)
                break
            case .readingHeader:
                if try continueRead(source: &data, target: pesScratch.getBlockBufferUnsafe(), targetLength: .headerSize) {
                    try setState(parseHeader() ? .readingHeaderExtension : .findingHeader)
                }
            case .readingHeaderExtension:
                let readLength = min(.maxHeaderExtensionSize, extendedHeaderLength)
                // Read as much of the extended header as we're interested in, and skip the rest.
                if try continueRead(source: &data, target: pesScratch.getBlockBufferUnsafe(), targetLength: readLength),
                   try continueRead(source: &data, target: nil, targetLength: readLength) {
                    try parseHeaderExtension(session: timestampAdjuster)
                    reader.packetStarted(
                        pesTime: pts,
                        decodeTime: dts,
                        flags: flags.union(dataAlignmentIndicator ? .dataAlignment : [])
                    )
                    setState(.readingBody)
                }
            case .readingBody:
                var readLength = data.readableBytes
                let padding = if let payloadSize { readLength - payloadSize } else { Int.zero }
                if padding > 0 {
                    readLength -= padding
                    data = try data.getSliceIgnoringReaderOffset(at: 0, length: data.readerIndex + readLength)
                }

                try! await reader.consume(data: &data, isolation)

                if let payloadSize {
                    // There are bytes left in data, see above, so this is not the end of input
                    self.payloadSize = payloadSize - readLength
                    if (payloadSize - readLength) == 0 {
                        try await reader.packetFinished(isolation)
                        setState(.readingHeader)
                    }
                }
            }
        }
    }

    func canConsumeSynthesizedEmptyPusi(isModeHls: Bool) throws -> Bool {
        // Pusi only payload to trigger end of sample data is only applicable if
        // pes does not have a length field and body is being read, another exclusion
        // is due to H262 streams possibly having, in HLS mode, a pes across more than one segment
        // which would trigger committing an unfinished sample in the middle of the access unit

        // Only call parseHeader if isModeHls is true and can parse header as some HLS streams may
        // contain packages.
        let headerParsed = try !isModeHls || parseHeader()
        return state == .readingBody
            && payloadSize == nil
            && !(isModeHls && false /* TODO: reader is H262Reader */)
            && headerParsed
    }

    private func setState(_ state: State) {
        self.state = state
        bytesRead = 0
    }

    private func continueRead(
        source: inout BlockBufferReader,
        target: CMBlockBuffer?,
        targetLength: Int
    ) throws -> Bool {
        let bytesToRead = min(source.readableBytes, targetLength - bytesRead)
        if bytesToRead <= 0 {
            return true
        } else if let target {
            let buffer = try source.readBytes(length: bytesToRead)
            try buffer.withUnsafeBytes {
                try target.replaceDataBytes(with: $0)
            }
        } else {
            source.moveReaderIndex(forwardBy: bytesToRead)
        }

        bytesRead += bytesToRead
        return bytesRead == targetLength
    }

    private func parseHeader() throws -> Bool {
        // Note: see ISO/IEC 13818-1, section 2.4.3.6 for detailed information on the format of
        // the header.
        pesScratch.setPosition(0)
        let startCodePrefix = try pesScratch.readBits(24)
        if (startCodePrefix != 0x000001) {
            // TODO: log "Unexpected start code prefix: \(startCodePrefix)"
            payloadSize = nil
            return false
        }

        pesScratch.skipBits(8) // stream_id.
        let packetLength = try pesScratch.readBits(16)
        pesScratch.skipBits(5) // '10' (2), PES_scrambling_control (2), PES_priority (1)
        dataAlignmentIndicator = try pesScratch.readBit()
        pesScratch.skipBits(2) // copyright (1), original_or_copy (1)
        ptsFlag = try pesScratch.readBit()
        dtsFlag = try pesScratch.readBit()
        // ESCR_flag (1), ES_rate_flag (1), DSM_trick_mode_flag (1),
        // additional_copy_info_flag (1), PES_CRC_flag (1), PES_extension_flag (1)
        pesScratch.skipBits(6)
        extendedHeaderLength = try pesScratch.readBits(8)

        if packetLength == 0 {
            payloadSize = nil
        } else {
            let payloadSize = packetLength
                + 6 // packetLength does not include the first 6 bytes
                - .headerSize
                - extendedHeaderLength

            if payloadSize < 0 {
                // TODO log "Found negative packet payload size: \(payloadSize)"
                self.payloadSize = nil
            } else {
                self.payloadSize = payloadSize
            }
        }

        return true
    }

    private func parseHeaderExtension(session: TimestampAdjuster.Session) throws {
        pesScratch.setPosition(0)
        pts = .invalid
        dts = .invalid

        guard ptsFlag else { return }

        pesScratch.skipBits(4) // '0010' or '0011'
        var pts33 = Int64(try pesScratch.readBits(3)) << 30
        pesScratch.skipBits(1) // marker_bit
        pts33 |= Int64(try pesScratch.readBits(15)) << 15
        pesScratch.skipBits(1) // marker_bit
        pts33 |= Int64(try pesScratch.readBits(15))
        pesScratch.skipBits(1) // marker_bit

        var dts33: Int64?
        if dtsFlag {
            pesScratch.skipBits(4) // '0011'
            var value = Int64(try pesScratch.readBits(3)) << 30
            pesScratch.skipBits(1) // marker_bit
            value |= Int64(try pesScratch.readBits(15)) << 15
            pesScratch.skipBits(1) // marker_bit
            value |= Int64(try pesScratch.readBits(15))
            pesScratch.skipBits(1) // marker_bit
            dts33 = value
        }

        (pts, dts) = session.adjustTS(pts33: pts33, dts33: dts33)
    }
}

private extension Int {
    static let headerSize = 9
    static let maxHeaderExtensionSize = 10
    static let pesScratchSize = 10 // max(.headerSize, .maxHeaderExtensionSize)
}
