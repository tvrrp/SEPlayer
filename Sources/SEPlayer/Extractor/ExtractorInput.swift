//
//  ExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public enum ExtractorInputReadResult {
    case bytesRead(ByteBuffer, Int)
    case endOfInput
}

public protocol ExtractorInput: DataReader {
    @discardableResult
    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult

    @discardableResult
    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool

    @discardableResult
    func read(allocation: Allocation, offset: Int, length: Int) throws -> DataReaderReadResult

    @discardableResult
    func readFully(allocation: Allocation, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool

    @discardableResult
    func skip(length: Int) throws -> DataReaderReadResult

    @discardableResult
    func skipFully(length: Int, allowEndOfInput: Bool) throws -> Bool

    @discardableResult
    func peek(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult

    @discardableResult
    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool

    @discardableResult
    func advancePeekPosition(length: Int, allowEndOfInput: Bool) throws -> Bool

    func resetPeekPosition()

    func getPeekPosition() -> Int

    func getPosition() -> Int

    func getLength() -> Int?

    func set<E: Error>(retryPosition: Int, using error: E) throws
}

extension ExtractorInput {
    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int) throws {
        try readFully(to: &buffer, offset: offset, length: length, allowEndOfInput: false)
    }

    func readFully(allocation: Allocation, offset: Int, length: Int) throws {
        try readFully(allocation: allocation, offset: offset, length: length, allowEndOfInput: false)
    }

    func skipFully(length: Int) throws {
        try skipFully(length: length, allowEndOfInput: false)
    }

    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int) throws {
        try peekFully(to: &buffer, offset: offset, length: length, allowEndOfInput: false)
    }

    func advancePeekPosition(length: Int) throws {
        try advancePeekPosition(length: length, allowEndOfInput: false)
    }
}
