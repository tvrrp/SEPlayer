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
    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult

    @discardableResult
    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool

    @discardableResult
    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult

    @discardableResult
    func readFully(allocation: Allocation, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool

    @discardableResult
    func skip(length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult

    @discardableResult
    func skipFully(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool

    @discardableResult
    func peek(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult

    @discardableResult
    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool

    @discardableResult
    func advancePeekPosition(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool

    func resetPeekPosition(isolation: isolated any Actor)

    func getPeekPosition(isolation: isolated any Actor) -> Int

    func getPosition(isolation: isolated any Actor) -> Int

    func getLength(isolation: isolated any Actor) -> Int?

    func set<E: Error>(retryPosition: Int, using error: E, isolation: isolated any Actor) throws
}

extension ExtractorInput {
    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws {
        try await readFully(to: &buffer, offset: offset, length: length, allowEndOfInput: false, isolation: isolation)
    }

    func readFully(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws {
        try await readFully(allocation: allocation, offset: offset, length: length, allowEndOfInput: false, isolation: isolation)
    }

    func skipFully(length: Int, isolation: isolated any Actor) async throws {
        try await skipFully(length: length, allowEndOfInput: false, isolation: isolation)
    }

    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws {
        try await peekFully(to: &buffer, offset: offset, length: length, allowEndOfInput: false, isolation: isolation)
    }

    func advancePeekPosition(length: Int, isolation: isolated any Actor) async throws {
        try await advancePeekPosition(length: length, allowEndOfInput: false, isolation: isolation)
    }
}
