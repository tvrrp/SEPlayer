//
//  ExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

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

import CoreMedia

public enum ExtractorInputReadResult<T> {
    case success(T)
    case endOfInput
}

public protocol ExtractorInput2: DataReader2 {
    func setPosition(_ position: Int, isolation: isolated any Actor)

    @discardableResult
    func read(lenght: Int, isolation: isolated any Actor) async throws -> CMBlockBuffer

    @discardableResult
    func readFully(lenght: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool)

    @discardableResult
    func skip(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) throws -> Bool

    func getPosition(isolation: isolated any Actor) -> Int

    func getLength(isolation: isolated any Actor) -> Int?

    func set<E: Error>(retryPosition: Int, using error: E, isolation: isolated any Actor) throws(E)
}

public extension ExtractorInput2 {
    @discardableResult
    func readFully(lenght: Int, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        let (blockBuffer, _) = try await readFully(lenght: lenght, allowEndOfInput: false, isolation: isolation)
        return blockBuffer
    }

    func skip(length: Int, isolation: isolated any Actor) throws {
        try skip(length: length, allowEndOfInput: false, isolation: isolation)
    }
}

public final class DefaultExtractorInput2: ExtractorInput2, DataReader2 {
    let syncActor: PlayerActor

    private let queue: Queue
    private let dataReader: DataReader2
    private var position: Int
    private var lenght: Int?

    public init(queue: Queue, dataReader: DataReader2, position: Int, lenght: Int?) {
        self.queue = queue
        self.dataReader = dataReader
        self.position = position
        self.lenght = lenght
        syncActor = queue.playerActor()
    }

    public func setPosition(_ position: Int, isolation: isolated any Actor) {
        self.position = position
    }

    // TODO: fix this (tinkering with range)
    public func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        let readRange = position..<(position + range.count)
        if let lenght, !(position..<(position + lenght)).contains(readRange) {
            throw EndOfFileError()
        }

        guard position == readRange.lowerBound else {
            throw EndOfFileError()
        }

        let blockBuffer = try await dataReader.read(range: readRange, isolation: isolation)
        position += blockBuffer.dataLength
        return blockBuffer
    }

    public func read(lenght: Int, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        assert(queue.isCurrent())
        let blockBuffer = try await dataReader.read(range: position..<(position + lenght), isolation: isolation)
        position += blockBuffer.dataLength
        return blockBuffer
    }

    public func readFully(
        lenght: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool) {
        assert(queue.isCurrent())
        let blockBuffer = try CMBlockBuffer()
        var bytesRead = 0

        do {
            while bytesRead < lenght {
                let upstreamBlockBuffer = try await dataReader.read(
                    range: position..<(position + lenght),
                    isolation: isolation
                )
                bytesRead += upstreamBlockBuffer.dataLength
                try blockBuffer.append(bufferReference: upstreamBlockBuffer)
            }

            position += bytesRead
            return (blockBuffer, false)
        } catch is EndOfFileError {
            guard allowEndOfInput else {
                throw EndOfFileError()
            }

            position += bytesRead
            return (blockBuffer, true)
        } catch {
            throw error
        }
    }

    public func skip(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) throws -> Bool {
        assert(queue.isCurrent())
        if let upperBound = self.lenght, (position + length) > upperBound {
            if allowEndOfInput {
                position = upperBound
                return true
            } else {
                throw EndOfFileError()
            }
        }

        position += length
        return true
    }

    public func getPosition(isolation: isolated any Actor) -> Int {
        assert(queue.isCurrent())
        return position
    }

    public func getLength(isolation: isolated any Actor) -> Int? {
        assert(queue.isCurrent())
        return lenght
    }

    public func set<E: Error>(retryPosition: Int, using error: E, isolation: isolated any Actor) throws(E) {
        assert(queue.isCurrent())
        self.position = retryPosition
        throw error
    }
}
