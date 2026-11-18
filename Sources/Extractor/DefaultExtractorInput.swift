//
//  DefaultExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation
import CoreMedia
import SEPlayerCommon

public final class DefaultExtractorInput: ExtractorInput, DataReader {
    public var isolation: any Actor { syncActor }
    let syncActor: PlayerActor

    private let queue: Queue
    private let dataReader: DataReader
    private var position: Int
    private var length: Int?

    /// Where the next peek reads, never behind ``position``: reading consumes what was peeked.
    private var peekPosition: Int {
        get { max(_peekPosition, position) }
        set { _peekPosition = newValue }
    }
    private var _peekPosition: Int

    public init(queue: Queue, dataReader: DataReader, position: Int, length: Int?) {
        self.queue = queue
        self.dataReader = dataReader
        self.position = position
        self.length = length
        _peekPosition = position
        syncActor = queue.playerActor()
    }

    public func setPosition(_ position: Int, _ isolation: isolated any Actor) {
        self.position = position
        _peekPosition = position
    }

    // TODO: fix this (tinkering with range)
    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        throw EndOfFileError()
    }

    public func read(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer {
        assert(queue.isCurrent())
        guard let blockBuffer = try await dataReader.read(range: position..<(position + length), isolation) else {
            // The end of the input.
            return try CMBlockBuffer()
        }

        position += blockBuffer.dataLength
        return blockBuffer
    }

    public func readFully(
        length: Int,
        allowEndOfInput: Bool,
        _ isolation: isolated any Actor
    ) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool) {
        assert(queue.isCurrent())
        let blockBuffer = try CMBlockBuffer()
        var bytesRead = 0
        var position = position

        while bytesRead < length {
            let readAmount = length - bytesRead

            switch try await dataReader.read(range: position..<(position + readAmount), isolation) {
            case let .some(upstreamBlockBuffer):
                guard !upstreamBlockBuffer.isEmpty else { fallthrough }
                bytesRead += upstreamBlockBuffer.dataLength
                position += upstreamBlockBuffer.dataLength
                try blockBuffer.append(bufferReference: upstreamBlockBuffer)
            case .none:
                guard allowEndOfInput else { throw EndOfFileError() }

                self.position += bytesRead
                return (blockBuffer, true)
            }
        }

        self.position += bytesRead
        return (blockBuffer, false)
    }

    public func skip(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) throws -> Bool {
        assert(queue.isCurrent())
        if let upperBound = self.length, (position + length) > upperBound {
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

    public func peek(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer {
        guard let blockBuffer = try await dataReader.read(range: peekPosition..<(peekPosition + length), isolation) else {
            throw EndOfFileError()
        }

        peekPosition += blockBuffer.dataLength
        return blockBuffer
    }

    public func peekFully(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool) {
        let blockBuffer = try CMBlockBuffer()
        var bytesPeeked = 0
        var peekPosition = peekPosition

        while bytesPeeked < length {
            let readAmount = length - bytesPeeked

            switch try await dataReader.read(range: peekPosition..<(peekPosition + readAmount), isolation) {
            case let .some(upstreamBlockBuffer):
                guard !upstreamBlockBuffer.isEmpty else { fallthrough }
                bytesPeeked += upstreamBlockBuffer.dataLength
                peekPosition += upstreamBlockBuffer.dataLength
                try blockBuffer.append(bufferReference: upstreamBlockBuffer)
            case .none:
                guard allowEndOfInput else { throw EndOfFileError() }

                self.peekPosition += bytesPeeked
                return (blockBuffer, true)
            }
        }

        self.peekPosition += bytesPeeked
        return (blockBuffer, false)
    }

    public func advancePeekPosition(length: Int, _ isolation: isolated any Actor) throws {
        try advancePeekPosition(length: length, allowEndOfInput: false, isolation)
    }

    public func advancePeekPosition(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) throws {
        // TODO: look at the max data position
        peekPosition += length
    }

    public func resetPeekPosition(_ isolation: isolated any Actor) {
        peekPosition = position
    }

    public func getPeekPosition(_ isolation: isolated any Actor) -> Int {
        peekPosition
    }

    public func getPosition(_ isolation: isolated any Actor) -> Int {
        assert(queue.isCurrent())
        return position
    }

    public func getLength(_ isolation: isolated any Actor) -> Int? {
        assert(queue.isCurrent())
        return length
    }

    public func set<E: Error>(retryPosition: Int, using error: E, _ isolation: isolated any Actor) throws(E) {
        assert(queue.isCurrent())
        self.position = retryPosition
        _peekPosition = retryPosition
        throw error
    }
}
