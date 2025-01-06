//
//  ByteBuffer+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

enum ByteBufferError: Error {
    case parse
    case endOfData
}

extension ByteBuffer {
    var upperBound: Int {
        readerIndex + readableBytes
    }

    @discardableResult
    mutating func readInt<T: FixedWidthInteger>(endianness: Endianness = .big, as: T.Type) throws -> T {
        if let value = self.readInteger(endianness: endianness, as: T.self) {
            return value
        } else {
            throw ByteBufferError.parse
        }
    }

    @discardableResult
    mutating func readData(count: Int) throws -> Data {
        if let data = readData(length: count) {
            return data
        } else {
            throw ByteBufferError.endOfData
        }
    }

    func slice(at offset: Int, length: Int) throws -> ByteBuffer {
        if let slice = getSlice(at: offset, length: length) {
            return slice
        } else {
            throw ByteBufferError.endOfData
        }
    }
}
