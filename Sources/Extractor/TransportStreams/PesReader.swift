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
    private var pesScratch: BlockBufferReader
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
        pesScratch = try BlockBufferReader()
        state = .findingHeader
        bytesRead = .zero
    }

    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        self.timestampAdjuster = session
        try reader.createTracks(
            output: extractorOutput,
            idGenerator: idGenerator
        )
    }

    func seek() {
        state = .findingHeader
        bytesRead = 0
        reader.seek()
    }

    func consume(
        data: inout BlockBufferReader,
        flags: TsPayload.PacketIndicators
    ) throws {
        let timestampAdjuster = try timestampAdjuster.checkNotNil()

        if flags.contains(.payloadUnitStart) {
            switch state {
            case .findingHeader, .readingHeader:
                // Expected.
                break
            case .readingHeaderExtension:
                SELogger.warning(.transportStream, "Unexpected start indicator while reading an extended header")
            case .readingBody:
                // If payloadSize is unset then the length of the previous packet was unspecified, and so
                // we only know that it's finished now that we've seen the start of the next one. This is
                // expected. If payloadSize is set, then the length of the previous packet was known, but
                // we didn't receive that amount of data. This is not expected.
                if let payloadSize {
                    SELogger.warning(
                        .transportStream,
                        "Unexpected start indicator: expected \(payloadSize) more bytes"
                    )
                }

                // Either way, notify the reader that it has now finished.
                try reader.packetFinished()
            }

            if data.readableBytes == 0 {
                try reader.endOfInputReached()
            }

            try setState(.readingHeader)
        }

        while data.readableBytes > 0 {
            switch state {
            case .findingHeader:
                data.moveReaderIndex(forwardBy: data.readableBytes)
            case .readingHeader:
                if try continueRead(source: &data, targetLength: .headerSize) {
                    try setState(parseHeader() ? .readingHeaderExtension : .findingHeader)
                }
            case .readingHeaderExtension:
                let readLength = min(.maxHeaderExtensionSize, extendedHeaderLength)
                // Read as much of the extended header as we're interested in, and skip the rest.
                if try continueRead(source: &data, targetLength: readLength),
                   continueSkip(source: &data, targetLength: extendedHeaderLength) {
                    try parseHeaderExtension(session: timestampAdjuster)
                    reader.packetStarted(
                        pesTime: pts,
                        decodeTime: dts,
                        flags: flags.union(dataAlignmentIndicator ? .dataAlignment : [])
                    )
                    try setState(.readingBody)
                }
            case .readingBody:
                var readLength = data.readableBytes
                let padding = if let payloadSize { readLength - payloadSize } else { Int.zero }
                if padding > 0 {
                    readLength -= padding
                    data = try data.getSliceIgnoringReaderOffset(at: 0, length: data.readerIndex + readLength)
                }

                try reader.consume(data: &data)

                if let payloadSize {
                    // There are bytes left in data, see above, so this is not the end of input
                    self.payloadSize = payloadSize - readLength
                    if (payloadSize - readLength) == 0 {
                        try reader.packetFinished()
                        try setState(.readingHeader)
                    }
                }
            }
        }
    }

    func canConsumeSynthesizedEmptyPusi(isModeHls: Bool) throws -> Bool {
        // A payload unit start without a payload ends the sample data only for a PES without a length field
        // whose body is being read.
        guard state == .readingBody, payloadSize == nil else { return false }

        // Only call parseHeader if isModeHls is true and can parse header as some HLS streams may
        // contain packages.
        return try !isModeHls || parseHeader()
    }

    private func setState(_ state: State) throws {
        self.state = state
        bytesRead = 0
        if state == .readingHeader {
            try pesScratch.clear()
        }
    }

    private func continueRead(source: inout BlockBufferReader, targetLength: Int) throws -> Bool {
        let bytesToRead = min(source.readableBytes, targetLength - bytesRead)
        if bytesToRead > 0 {
            try pesScratch.extend(with: source.readSlice(length: bytesToRead))
            bytesRead += bytesToRead
        }
        return bytesRead == targetLength
    }

    private func continueSkip(source: inout BlockBufferReader, targetLength: Int) -> Bool {
        let bytesToSkip = min(source.readableBytes, targetLength - bytesRead)
        if bytesToSkip > 0 {
            source.moveReaderIndex(forwardBy: bytesToSkip)
            bytesRead += bytesToSkip
        }
        return bytesRead == targetLength
    }

    private func parseHeader() throws -> Bool {
        // Note: see ISO/IEC 13818-1, section 2.4.3.6 for detailed information on the format of
        // the header.
        var header = BlockBufferBitReader(reader: pesScratch)
        let startCodePrefix = try header.readBits(24)
        if startCodePrefix != 0x000001 {
            SELogger.warning(.transportStream, "Unexpected start code prefix: \(startCodePrefix)")
            payloadSize = nil
            return false
        }

        header.skipBits(8) // stream_id.
        let packetLength = try header.readBits(16)
        header.skipBits(5) // '10' (2), PES_scrambling_control (2), PES_priority (1)
        dataAlignmentIndicator = try header.readBit()
        header.skipBits(2) // copyright (1), original_or_copy (1)
        ptsFlag = try header.readBit()
        dtsFlag = try header.readBit()
        // ESCR_flag (1), ES_rate_flag (1), DSM_trick_mode_flag (1),
        // additional_copy_info_flag (1), PES_CRC_flag (1), PES_extension_flag (1)
        header.skipBits(6)
        extendedHeaderLength = try header.readBits(8)

        if packetLength == 0 {
            payloadSize = nil
        } else {
            let payloadSize = packetLength
                + 6 // packetLength does not include the first 6 bytes
                - .headerSize
                - extendedHeaderLength

            if payloadSize < 0 {
                SELogger.warning(.transportStream, "Found negative packet payload size: \(payloadSize)")
                self.payloadSize = nil
            } else {
                self.payloadSize = payloadSize
            }
        }

        return true
    }

    private func parseHeaderExtension(session: TimestampAdjuster.Session) throws {
        var headerExtension = BlockBufferBitReader(reader: pesScratch)
        headerExtension.setPosition(.headerSize * 8)
        pts = .invalid
        dts = .invalid

        guard ptsFlag else { return }

        headerExtension.skipBits(4) // '0010' or '0011'
        var pts33 = Int64(try headerExtension.readBits(3)) << 30
        headerExtension.skipBits(1) // marker_bit
        pts33 |= Int64(try headerExtension.readBits(15)) << 15
        headerExtension.skipBits(1) // marker_bit
        pts33 |= Int64(try headerExtension.readBits(15))
        headerExtension.skipBits(1) // marker_bit

        var dts33: Int64?
        if dtsFlag {
            headerExtension.skipBits(4) // '0011'
            var value = Int64(try headerExtension.readBits(3)) << 30
            headerExtension.skipBits(1) // marker_bit
            value |= Int64(try headerExtension.readBits(15)) << 15
            headerExtension.skipBits(1) // marker_bit
            value |= Int64(try headerExtension.readBits(15))
            headerExtension.skipBits(1) // marker_bit
            dts33 = value
        }

        (pts, dts) = session.adjustTS(pts33: pts33, dts33: dts33)
    }
}

private extension Int {
    static let headerSize = 9
    static let maxHeaderExtensionSize = 10
}
