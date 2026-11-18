//
//  SubtitleBitReader.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import SEPlayerCommon

/// Reads bits of subtitle data, the most significant first, in place: the bytes are not copied. Reads past the end
/// give zeros, so a truncated sample ends a parser's loop rather than failing the extraction.
struct SubtitleBitReader<Bytes: RandomAccessCollection> where Bytes.Element == UInt8, Bytes.Index == Int {
    private let bytes: Bytes
    /// In bits, from the start of `bytes`.
    private(set) var position = 0
    /// The byte the reads are in, read once for its bits.
    private var currentByteIndex = -1
    private var currentByte: UInt8 = 0

    init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    var bitsLeft: Int { max(0, bytes.count * 8 - position) }
    var bytePosition: Int { position >> 3 }

    mutating func readBit() -> Bool {
        readBits(1) == 1
    }

    mutating func readBits(_ count: Int) -> Int {
        var value = 0
        for _ in 0 ..< count {
            let byteIndex = position >> 3
            if byteIndex != currentByteIndex {
                currentByteIndex = byteIndex
                currentByte = byteIndex < bytes.count ? bytes[bytes.startIndex + byteIndex] : 0
            }
            value = value << 1 | Int(currentByte >> (7 - position & 7)) & 1
            position += 1
        }
        return value
    }

    /// The next `count` whole bytes, from the next byte boundary, as a part of the bytes rather than a copy.
    mutating func readBytes(_ count: Int) -> Bytes.SubSequence {
        byteAlign()
        let start = bytes.startIndex + min(bytePosition, bytes.count)
        let end = min(start + count, bytes.endIndex)
        position = (bytePosition + count) * 8
        return bytes[start ..< end]
    }

    mutating func skipBits(_ count: Int) {
        position += max(0, count)
    }

    mutating func byteAlign() {
        position = (position + 7) & ~7
    }
}
