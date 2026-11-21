//
//  SampleEntryBox.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.10.2026.
//

import Foundation
import SEPlayerCommon

/// A box inside a sample entry.
struct SampleEntryBox {
    /// The type as the file has it, which `MP4Box.BoxType` may not name.
    let rawType: UInt32
    /// The bytes after the header.
    let payload: BlockBufferReader
    /// The whole box, from its size field.
    let box: BlockBufferReader

    var type: MP4Box.BoxType? { MP4Box.BoxType(rawValue: rawType) }

    /// The boxes of `reader` from `offset` on, in order. The reader's indices start at 0.
    ///
    /// Stops at a box that doesn't fit, or at a size of zero, which QuickTime writes to end a list of boxes.
    ///
    /// - Returns: The boxes, and whether they filled the reader exactly, or up to a terminating size of zero.
    static func boxes(in reader: BlockBufferReader, from offset: Int) -> (boxes: [SampleEntryBox], isWellFormed: Bool) {
        var boxes: [SampleEntryBox] = []
        var position = offset
        let end = reader.readerIndex + reader.readableBytes
        while position < end {
            guard end - position >= 4, let size = try? Int(reader.getInt(at: position, as: UInt32.self)) else {
                return (boxes, false)
            }
            if size == 0 { return (boxes, true) }
            guard size >= MP4Box.headerSize, end - position >= size,
                  let rawType = try? reader.getInt(at: position + 4, as: UInt32.self),
                  let box = try? reader.getSlice(at: position, length: size),
                  let payload = try? reader.getSlice(at: position + MP4Box.headerSize, length: size - MP4Box.headerSize) else {
                return (boxes, false)
            }
            boxes.append(SampleEntryBox(rawType: rawType, payload: payload, box: box))
            position += size
        }
        return (boxes, true)
    }
}

extension UInt32 {
    /// The four characters of a code such as a box type.
    var fourCharacterCode: String { FourCharacterCode(self).description }
}

extension FourCharacterCode {
    init(_ type: MP4Box.BoxType) {
        self.init(type.rawValue)
    }
}

extension BlockBufferReader {
    /// The bytes from `offset` to the end, as a reader whose indices start at 0.
    func slice(from offset: Int) throws -> BlockBufferReader {
        try getSlice(at: offset, length: readerIndex + readableBytes - offset)
    }

    /// The big-endian bytes of a box of `type` with `payload`, for cookies that wrap the codec's boxes.
    static func box(type: MP4Box.BoxType, payload: [UInt8]) -> [UInt8] {
        let size = UInt32(MP4Box.headerSize + payload.count)
        return size.bigEndianBytes + type.rawValue.bigEndianBytes + payload
    }

    /// The box of size zero that ends a QuickTime list of boxes, with eight bytes as a box header has.
    static let terminatorBox: [UInt8] = UInt32(MP4Box.headerSize).bigEndianBytes + UInt32(0).bigEndianBytes
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
