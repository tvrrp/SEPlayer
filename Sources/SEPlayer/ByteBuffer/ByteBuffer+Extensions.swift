//
//  ByteBuffer+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

enum ByteBufferError: Error {
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
            throw ByteBufferError.endOfData
        }
    }

    @discardableResult
    mutating func bytes(count: Int) throws -> [UInt8] {
        if let data = readBytes(length: count) {
            return data
        } else {
            throw ByteBufferError.endOfData
        }
    }

    @discardableResult
    mutating func readData(count: Int, byteTransferStrategy: ByteTransferStrategy = .automatic) throws -> Data {
        if let data = readData(length: count, byteTransferStrategy: byteTransferStrategy) {
            return data
        } else {
            throw ByteBufferError.endOfData
        }
    }

    mutating func getSliceIgnoringReaderOffset(at offset: Int, length: Int) throws -> ByteBuffer {
        let currentOffset = readerIndex
        moveReaderIndex(to: offset)
        let slice = try slice(at: offset, length: length)
        moveReaderIndex(to: currentOffset)
        return slice
    }

    func slice(at offset: Int? = nil, length: Int) throws -> ByteBuffer {
        if let slice = getSlice(at: offset ?? readerIndex, length: length) {
            return slice
        } else {
            throw ByteBufferError.endOfData
        }
    }

    @discardableResult
    mutating func readThrowingSlice(length: Int) throws -> ByteBuffer {
        if let slice = readSlice(length: length) {
            return slice
        } else {
            throw ByteBufferError.endOfData
        }
    }

    mutating func readFixedPoint16_16() throws -> Int {
        let firstValue = try readInt(as: UInt8.self)
        let secondValue = try readInt(as: UInt8.self)
        let result = (UInt16(firstValue) << 8) | UInt16(secondValue)

        moveReaderIndex(forwardBy: 2)
        return Int(result)
    }
}

extension Int {
    init<T: FixedWidthInteger>(reading buffer: inout ByteBuffer, type: T.Type, endianness: Endianness = .big) throws {
        if let value = buffer.readInteger(endianness: endianness, as: type) {
            self.init(value)
        } else {
            throw ByteBufferError.endOfData
        }
    }

    init<T: FixedWidthInteger>(peeking buffer: inout ByteBuffer, type: T.Type, endianness: Endianness = .big) throws {
        if let value = buffer.getInteger(at: buffer.readerIndex, endianness: endianness, as: type) {
            self.init(value)
        } else {
            throw ByteBufferError.endOfData
        }
    }
}
