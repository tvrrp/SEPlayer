//
//  BlockBufferReader+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public extension BlockBufferReader {
    /// The `length` bytes at `offset`, whatever the reader index is.
    mutating func getSliceIgnoringReaderOffset(at offset: Int, length: Int) throws -> BlockBufferReader {
        let currentOffset = readerIndex
        moveReaderIndex(to: offset)
        let slice = try getSlice(at: offset, length: length)
        moveReaderIndex(to: currentOffset)
        return slice
    }

    /// Reads a byte order mark, if the next bytes are one.
    ///
    /// - Returns: The encoding the mark names, or `nil` without a mark.
    mutating func readUtfCharsetFromBom() throws -> String.Encoding? {
        if readableBytes >= 3 {
            let b0: UInt8 = try getInt(at: readerIndex)
            let b1: UInt8 = try getInt(at: readerIndex + 1)
            let b2: UInt8 = try getInt(at: readerIndex + 2)
            if b0 == 0xEF, b1 == 0xBB, b2 == 0xBF {
                moveReaderIndex(forwardBy: 3)
                return .utf8
            }
        }

        if readableBytes >= 2 {
            let b0: UInt8 = try getInt(at: readerIndex)
            let b1: UInt8 = try getInt(at: readerIndex + 1)
            if b0 == 0xFE, b1 == 0xFF {
                moveReaderIndex(forwardBy: 2)
                return .utf16BigEndian
            } else if b0 == 0xFF, b1 == 0xFE {
                moveReaderIndex(forwardBy: 2)
                return .utf16LittleEndian
            }
        }

        return nil
    }
}
