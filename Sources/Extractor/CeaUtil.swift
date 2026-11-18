//
//  CeaUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.08.2026.
//

import CoreMedia
import SEPlayerCommon

/// Finds CEA-608/708 caption data in SEI messages of H.264 and H.265 video, as ATSC A/53 carries it.
enum CeaUtil {
    /// The caption data of one SEI message: `cc_count` packets of three bytes, each `cc_valid`/`cc_type` followed by two
    /// bytes of data.
    struct CcData {
        let presentationTime: CMTime
        /// The packets, in the SEI message's buffer.
        let packets: BlockBufferReader
    }

    private static let payloadTypeUserDataRegistered = 4
    private static let countryCodeUnitedStates = 0xB5
    private static let providerCodeAtsc = 0x31
    private static let providerCodeDirecTV = 0x2F
    /// `GA94`.
    private static let userIdentifierGA94: UInt32 = 0x4741_3934
    private static let userDataTypeCodeMpegCc = 0x03

    /// The caption data in the unescaped content of an SEI NAL unit, without its start code and header.
    static func ccData(presentationTime: CMTime, seiBuffer: inout BlockBufferReader) throws -> [CcData] {
        var result: [CcData] = []
        // The last byte is rbsp_trailing_bits.
        while seiBuffer.readableBytes > 1 {
            let payloadType = try readNon255TerminatedValue(&seiBuffer)
            let payloadSize = try readNon255TerminatedValue(&seiBuffer)
            guard let payloadType, let payloadSize, payloadSize <= seiBuffer.readableBytes else {
                // A malformed message, as in an encrypted NAL unit: the rest can't be read either.
                SELogger.verbose(.transportStream, "Skipping the rest of a malformed SEI NAL unit")
                break
            }
            let nextPayloadPosition = seiBuffer.readerIndex + payloadSize

            if payloadType == payloadTypeUserDataRegistered, payloadSize >= 8 {
                let countryCode = try Int(seiBuffer.readInt(as: UInt8.self))
                let providerCode = try Int(seiBuffer.readInt(as: UInt16.self))
                var userIdentifier: UInt32 = 0
                if providerCode == providerCodeAtsc {
                    userIdentifier = try seiBuffer.readInt(as: UInt32.self)
                }
                let userDataTypeCode = try Int(seiBuffer.readInt(as: UInt8.self))
                if providerCode == providerCodeDirecTV {
                    seiBuffer.moveReaderIndex(forwardBy: 1) // user_data_length
                }
                var isCaption = countryCode == countryCodeUnitedStates
                    && (providerCode == providerCodeAtsc || providerCode == providerCodeDirecTV)
                    && userDataTypeCode == userDataTypeCodeMpegCc
                if providerCode == providerCodeAtsc {
                    isCaption = isCaption && userIdentifier == userIdentifierGA94
                }
                if isCaption, let ccData = try ccData(
                    presentationTime: presentationTime,
                    buffer: &seiBuffer,
                    limit: nextPayloadPosition
                ) {
                    result.append(ccData)
                }
            }
            seiBuffer.moveReaderIndex(to: nextPayloadPosition)
        }
        return result
    }

    /// Reads `cc_data()`: nothing if its process flag is off.
    private static func ccData(presentationTime: CMTime, buffer: inout BlockBufferReader, limit: Int) throws -> CcData? {
        guard buffer.readerIndex + 2 <= limit else { return nil }
        let firstByte = try buffer.readInt(as: UInt8.self)
        guard firstByte & 0x40 != 0 else { return nil } // process_cc_data_flag
        let ccCount = Int(firstByte & 0x1F)
        buffer.moveReaderIndex(forwardBy: 1) // em_data
        let length = min(ccCount * 3, limit - buffer.readerIndex) / 3 * 3
        guard length > 0 else { return nil }
        return try CcData(presentationTime: presentationTime, packets: buffer.readSlice(length: length))
    }

    /// A value coded as a run of 0xFF bytes and a last byte, each added; `nil` at the end of the buffer.
    private static func readNon255TerminatedValue(_ buffer: inout BlockBufferReader) throws -> Int? {
        var value = 0
        while buffer.readableBytes > 0 {
            let byte = try Int(buffer.readInt(as: UInt8.self))
            value += byte
            if byte != 0xFF { return value }
        }
        return nil
    }
}
