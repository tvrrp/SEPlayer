//
//  Ac4Util.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import SEPlayerCommon

/// Reads the sync frames of AC-4 streams, ETSI TS 103 190.
enum Ac4Util {
    static let ac40SyncWord = 0xAC40
    /// The sync word of frames followed by a CRC word.
    static let ac41SyncWord = 0xAC41
    /// The highest bitrate, in bytes per second.
    static let maxRateBytesPerSecond = 2688 * 1000 / 8
    /// The size of the header ``sampleHeader(size:)`` writes.
    static let sampleHeaderSize = 7
    /// The bytes ``parseAc4SyncFrameInfo(_:)`` reads at most.
    static let headerSizeForParser = 16

    /// What the header of a sync frame says.
    struct SyncFrameInfo {
        let bitstreamVersion: Int
        let sampleRate: Int
        let channelCount: Int
        let frameSize: Int
        let sampleCount: Int
    }

    /// Reads the header of the sync frame at the start of `data`, Annex G.
    static func parseAc4SyncFrameInfo(_ data: inout BlockBufferBitReader) throws -> SyncFrameInfo {
        var headerSize = 0
        let syncWord = try data.readBits(16)
        headerSize += 2
        var frameSize = try data.readBits(16)
        headerSize += 2
        if frameSize == 0xFFFF {
            frameSize = try data.readBits(24)
            headerSize += 3 // Extended frame_size.
        }
        frameSize += headerSize
        if syncWord == ac41SyncWord {
            frameSize += 2 // crc_word
        }
        var bitstreamVersion = try data.readBits(2)
        if bitstreamVersion == 3 {
            bitstreamVersion += try readVariableBits(&data, bitsPerRead: 2)
        }
        let sequenceCounter = try data.readBits(10)
        if try data.readBit() { // b_wait_frames
            if try data.readBits(3) > 0 { // wait_frames
                data.skipBits(2) // reserved
            }
        }
        let sampleRate = try data.readBit() ? 48000 : 44100
        let frameRateIndex = try data.readBits(4)
        var sampleCount = 0
        if sampleRate == 44100, frameRateIndex == 13 {
            sampleCount = sampleCounts[frameRateIndex]
        } else if sampleRate == 48000, frameRateIndex < sampleCounts.count {
            sampleCount = sampleCounts[frameRateIndex]
            // The fractional frame rates alternate frames one sample longer.
            switch sequenceCounter % 5 {
            case 1,
                 3:
                if frameRateIndex == 3 || frameRateIndex == 8 { sampleCount += 1 }
            case 2:
                if frameRateIndex == 8 || frameRateIndex == 11 { sampleCount += 1 }
            case 4:
                if frameRateIndex == 3 || frameRateIndex == 8 || frameRateIndex == 11 { sampleCount += 1 }
            default:
                break
            }
        }
        return SyncFrameInfo(
            bitstreamVersion: bitstreamVersion,
            sampleRate: sampleRate,
            channelCount: 2,
            frameSize: frameSize,
            sampleCount: sampleCount
        )
    }

    /// The size of the sync frame whose header starts `data`, or `nil` if there are too few bytes.
    static func parseAc4SyncFrameSize<C: RandomAccessCollection<UInt8>>(_ data: C, syncWord: Int) -> Int?
    where C.Index == Int {
        guard data.count >= 7 else { return nil }
        let start = data.startIndex
        var headerSize = 2 // syncword
        var frameSize = Int(data[start + 2]) << 8 | Int(data[start + 3])
        headerSize += 2
        if frameSize == 0xFFFF {
            frameSize = Int(data[start + 4]) << 16 | Int(data[start + 5]) << 8 | Int(data[start + 6])
            headerSize += 3
        }
        if syncWord == ac41SyncWord {
            headerSize += 2
        }
        return frameSize + headerSize
    }

    /// The number of audio samples of the sync frame whose header starts `data`.
    static func parseAc4SyncFrameAudioSampleCount(_ data: BlockBufferReader) throws -> Int {
        var bits = BlockBufferBitReader(reader: data)
        return try parseAc4SyncFrameInfo(&bits).sampleCount
    }

    /// The sync frame header that a raw AC-4 frame of `size` bytes is given, so that it can be decoded alone.
    static func sampleHeader(size: Int) -> [UInt8] {
        [
            0xAC, 0x40, 0xFF, 0xFF,
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ]
    }
}

private extension Ac4Util {
    /// The audio samples of a frame, by frame rate index: 23.976, 24, 25, 29.97, 30, 47.95, 48, 50, 59.94, 60, 100,
    /// 119.88, 120 and 23.438 fps.
    static let sampleCounts = [2002, 2000, 1920, 1601, 1600, 1001, 1000, 960, 800, 800, 480, 400, 400, 2048]

    static func readVariableBits(_ data: inout BlockBufferBitReader, bitsPerRead: Int) throws -> Int {
        var value = 0
        while true {
            value += try data.readBits(bitsPerRead)
            guard try data.readBit() else { break }
            value += 1
            value <<= bitsPerRead
        }
        return value
    }
}
