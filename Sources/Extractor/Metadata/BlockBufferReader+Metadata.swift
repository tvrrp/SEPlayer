//
//  BlockBufferReader+Metadata.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import Foundation
import SEPlayerCommon

extension BlockBufferReader {
    /// Reads a big-endian integer of three bytes.
    mutating func readUInt24() throws -> Int {
        let high = try Int(readInt(as: UInt8.self))
        let low = try Int(readInt(as: UInt16.self))
        return high << 16 | low
    }

    /// Reads an integer whose four bytes each hold 7 bits, as ID3 sizes are written.
    mutating func readSynchSafeInt() throws -> Int {
        try Self.synchSafeInt(readInt(as: UInt32.self))
    }

    /// The value of an integer whose four bytes each hold 7 bits.
    static func synchSafeInt(_ value: UInt32) -> Int {
        let bytes = (0 ..< 4).map { Int(value >> (8 * $0)) & 0x7F }
        return bytes[0] | bytes[1] << 7 | bytes[2] << 14 | bytes[3] << 21
    }

    /// Reads all the bytes that are left.
    mutating func readRemainingData() throws -> Data {
        try readData(length: readableBytes)
    }

    /// Reads a string of a tag: up to its terminator, which is moved past, or to the end of the data, as tags often
    /// leave the terminator out. The terminator is two zero bytes at an even offset for UTF-16, one otherwise.
    mutating func readTerminatedString(encoding: String.Encoding = .utf8) throws -> String {
        let isWide = [.utf16, .utf16BigEndian, .utf16LittleEndian].contains(encoding)
        let bytes = readableBytesView
        let terminator = if isWide {
            stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).first { bytes[$0] == 0 && bytes[$0 + 1] == 0 }
        } else {
            bytes.firstIndex(of: 0)
        }
        let string = try readString(length: (terminator ?? bytes.endIndex) - bytes.startIndex, lossyEncoding: encoding)
        try skip(min(isWide ? 2 : 1, readableBytes))
        return string
    }

    /// Reads `length` bytes as a string. Bytes that aren't valid in `encoding` are read as ISO-8859-1, which any are.
    mutating func readString(length: Int, lossyEncoding encoding: String.Encoding = .utf8) throws -> String {
        let data = try readData(length: length)
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
