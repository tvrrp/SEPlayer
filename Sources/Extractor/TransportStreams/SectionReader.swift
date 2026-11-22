//
//  SectionReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 11.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ts.SectionReader
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Reads section data packets and feeds the whole sections to a given ``SectionPayloadReader``.
/// Useful information on PSI sections can be found in ISO/IEC 13818-1, section 2.4.4.
final class SectionReader: TsPayload.Reader {
    private let reader: any SectionPayloadReader
    private var sectionData: BlockBufferReader

    private var totalSectionLength = 0
    private var bytesRead = 0
    private var sectionSyntaxIndicator = false
    private var waitingForPayloadStart = false

    init(reader: any SectionPayloadReader) throws {
        self.reader = reader
        sectionData = try BlockBufferReader()
    }

    func initialize(
        session: TimestampAdjuster.Session,
        extractorOutput: any ExtractorOutput,
        idGenerator: TsPayload.TrackIdGenerator
    ) throws {
        try reader.initialize(
            session: session,
            extractorOutput: extractorOutput,
            idGenerator: idGenerator
        )
        waitingForPayloadStart = true
    }

    func seek() {
        waitingForPayloadStart = true
    }

    func consume(
        data: inout SEPlayerCommon.BlockBufferReader,
        flags: TsPayload.PacketIndicators
    ) throws {
        let payloadUnitStartIndicator = flags.contains(.payloadUnitStart)
        var payloadStartPosition: Int?
        if payloadUnitStartIndicator {
            let payloadStartOffset = try Int(data.readInt(as: UInt8.self))
            payloadStartPosition = data.readerIndex + payloadStartOffset
        }

        if waitingForPayloadStart, let payloadStartPosition {
            // A pointer past the end of the packet: the section isn't here.
            guard payloadStartPosition <= data.capacity else { return }
            waitingForPayloadStart = false
            data.moveReaderIndex(to: payloadStartPosition)
            bytesRead = 0
        }

        while data.readableBytes > 0 {
            if bytesRead < .sectionHeaderLength {
                // See ISO/IEC 13818-1, section 2.4.4.3 for detailed information on the format of the header.
                if bytesRead == 0 {
                    let tableId: UInt8 = try data.readInt()
                    data.moveReaderIndex(to: data.readerIndex - 1)
                    if tableId == 0xFF { // forbidden value
                        // No more sections in this ts packet.
                        waitingForPayloadStart = true
                        return
                    }
                    // A new section: none of the last one's bytes.
                    sectionData = try BlockBufferReader()
                }

                let headerBytesToRead = min(data.readableBytes, .sectionHeaderLength - bytesRead)
                try sectionData.extend(with: data.readSlice(length: headerBytesToRead))
                bytesRead += headerBytesToRead

                if bytesRead == .sectionHeaderLength {
                    sectionData.moveReaderIndex(to: 0)
                    sectionData = try sectionData.readSlice(length: .sectionHeaderLength)
                    sectionData.moveReaderIndex(forwardBy: 1) // Skip table id (8).

                    let secondHeaderByte: UInt8 = try sectionData.readInt()
                    let thirdHeaderByte: UInt8 = try sectionData.readInt()
                    sectionSyntaxIndicator = (secondHeaderByte & 0x80) != 0
                    // section_length (12)
                    let sectionLength = Int(secondHeaderByte & 0x0F) << 8 | Int(thirdHeaderByte)
                    totalSectionLength = sectionLength + .sectionHeaderLength
                }
            } else {
                // Reading the body.
                let bodyBytesToRead = min(data.readableBytes, totalSectionLength - bytesRead)
                // sectionData has been sized large enough for totalSectionLength when reading the header.
                try sectionData.extend(with: data.readSlice(length: bodyBytesToRead))
                bytesRead += bodyBytesToRead
                if bytesRead == totalSectionLength {
                    if sectionSyntaxIndicator {
                        // This section has common syntax as defined in ISO/IEC 13818-1, section 2.4.4.11.
                        let slice = sectionData.bytesView[0 ..< totalSectionLength]
                        if totalSectionLength < .crcLength || CrcUtil.computeCrc32(slice, mode: .mpeg2) != 0 {
                            // The CRC is invalid so discard the section.
                            waitingForPayloadStart = true
                            return
                        }
                        sectionData = try sectionData.getSliceIgnoringReaderOffset(
                            at: 0,
                            length: totalSectionLength - .crcLength // Exclude the CRC_32 field.
                        )
                    } else {
                        // This is a private section with private defined syntax.
                        sectionData = try sectionData.getSliceIgnoringReaderOffset(at: 0, length: totalSectionLength)
                    }

                    try reader.consume(sectionData: &sectionData)
                    // The next section of the packet, if any, starts here.
                    bytesRead = 0
                }
            }
        }
    }
}

private extension Int {
    static let sectionHeaderLength = 3
    static let crcLength = 4
}
