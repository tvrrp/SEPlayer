//
//  TsUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.08.2026.
//

import Foundation
import SEPlayerCommon

enum TsUtil {
    static func findSyncBytePosition(
        _ reader: BlockBufferReader,
        startPosition: Int,
        limitPosition: Int
    ) throws -> Int {
        var position = startPosition
        while position < limitPosition,
              try reader.getInt(at: position, as: UInt8.self) != TSConstants.syncByte {
            position += 1
        }
        return position
    }

    static func readPcrFromPacket(
        _ reader: BlockBufferReader,
        startOfPacket: Int,
        pcrPid: Int
    ) throws -> Int64? {
        var reader = reader
        reader.moveReaderIndex(to: startOfPacket)
        if reader.readableBytes < 5 {
            // Header = 4 bytes, adaptationFieldLength = 1 byte.
            return nil
        }
        let tsPacketHeader = try reader.readInt(as: UInt32.self)
        if (tsPacketHeader & 0x800000) != 0 {
            // transport_error_indicator.
            return nil
        }
        let pid = Int((tsPacketHeader & 0x1FFF00) >> 8)
        if pid != pcrPid {
            return nil
        }
        let adaptationFieldExists = (tsPacketHeader & 0x20) != 0
        if !adaptationFieldExists {
            return nil
        }

        let adaptationFieldLength = try reader.readInt(as: UInt8.self)
        if adaptationFieldLength >= 7, reader.readableBytes >= 7 {
            let flags = try reader.readInt(as: UInt8.self)
            let pcrFlagSet = (flags & 0x10) == 0x10
            if pcrFlagSet {
                let pcrBytes = try reader.readBytes(length: 6)
                return readPcrValueFromPcrBytes(pcrBytes)
            }
        }
        return nil
    }

    /// Returns whether a TS packet starts at `searchPosition` according to the MPEG-TS
    /// synchronization recommendations.
    ///
    /// ISO/IEC 13818-1:2015 Annex G recommends that 5 sync bytes emulating the start of 5
    /// consecutive TS packets should never occur as part of the TS packets' contents. So, this
    /// method returns true when `reader` contains a sync byte at `searchPosition`, and said sync
    /// byte is also one of five consecutive sync bytes separated from each other by the size of a
    /// TS packet.
    static func isStartOfTsPacket(
        _ reader: BlockBufferReader,
        startPosition: Int,
        limitPosition: Int,
        position: Int
    ) throws -> Bool {
        var consecutiveSyncByteCount = 0
        for i in -4 ... 4 {
            let currentPosition = position + i * TSConstants.packetSize
            if try currentPosition < startPosition
                || currentPosition >= limitPosition
                || reader.getInt(at: currentPosition, as: UInt8.self) != TSConstants.syncByte {
                consecutiveSyncByteCount = 0
            } else {
                consecutiveSyncByteCount += 1
                if consecutiveSyncByteCount == 5 {
                    return true
                }
            }
        }
        return false
    }

    private static func readPcrValueFromPcrBytes(_ pcrBytes: [UInt8]) -> Int64 {
        Int64(pcrBytes[0]) << 25
            | Int64(pcrBytes[1]) << 17
            | Int64(pcrBytes[2]) << 9
            | Int64(pcrBytes[3]) << 1
            | Int64(pcrBytes[4]) >> 7
    }
}
