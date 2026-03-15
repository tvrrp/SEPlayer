//
//  ByteBuffer+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public extension ByteBuffer {
    var upperBound: Int {
        readerIndex + readableBytes
    }

    @discardableResult
    mutating func readInt<T: FixedWidthInteger>(endianness: Endianness = .big, as: T.Type) throws -> T {
        if let value = self.readInteger(endianness: endianness, as: T.self) {
            return value
        } else {
            throw EndOfFileError()
        }
    }

    @discardableResult
    mutating func bytes(count: Int) throws -> [UInt8] {
        if let data = readBytes(length: count) {
            return data
        } else {
            throw EndOfFileError()
        }
    }

    @discardableResult
    mutating func readData(count: Int, byteTransferStrategy: ByteTransferStrategy = .automatic) throws -> Data {
        if let data = readData(length: count, byteTransferStrategy: byteTransferStrategy) {
            return data
        } else {
            throw EndOfFileError()
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
            throw EndOfFileError()
        }
    }

    @discardableResult
    mutating func readThrowingSlice(length: Int) throws -> ByteBuffer {
        if let slice = readSlice(length: length) {
            return slice
        } else {
            throw EndOfFileError()
        }
    }

    mutating func readFixedPoint16_16() throws -> Int {
        let firstValue = try readInt(as: UInt8.self)
        let secondValue = try readInt(as: UInt8.self)
        let result = (UInt16(firstValue) << 8) | UInt16(secondValue)

        moveReaderIndex(forwardBy: 2)
        return Int(result)
    }

    mutating func readUtfCharsetFromBom() -> String.Encoding? {
        if readableBytes >= 3,
           let b0: UInt8 = getInteger(at: readerIndex),
           let b1: UInt8 = getInteger(at: readerIndex + 1),
           let b2: UInt8 = getInteger(at: readerIndex + 2),
           b0 == 0xEF, b1 == 0xBB, b2 == 0xBF
        {
            moveReaderIndex(forwardBy: 3)
            return .utf8
        }

        if readableBytes >= 2,
           let b0: UInt8 = getInteger(at: readerIndex),
           let b1: UInt8 = getInteger(at: readerIndex + 1)
        {
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

    mutating func readString(length: Int, encoding: String.Encoding) throws -> String {
        if let string = readString(length: length, encoding: encoding) {
            return string
        } else {
            throw EndOfFileError()
        }
    }
}

public extension Int {
    init<T: FixedWidthInteger>(reading buffer: inout ByteBuffer, type: T.Type, endianness: Endianness = .big) throws {
        if let value = buffer.readInteger(endianness: endianness, as: type) {
            self.init(value)
        } else {
            throw EndOfFileError()
        }
    }

    init<T: FixedWidthInteger>(peeking buffer: inout ByteBuffer, type: T.Type, endianness: Endianness = .big) throws {
        if let value = buffer.getInteger(at: buffer.readerIndex, endianness: endianness, as: type) {
            self.init(value)
        } else {
            throw EndOfFileError()
        }
    }
}
