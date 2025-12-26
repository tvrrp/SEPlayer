//
//  DefaltExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSRange

final class DefaltExtractorInput: ExtractorInput {
    private let dataReader: DataReader
    private let streamLength: Int?

    private var scratchBuffer: ByteBuffer
    private var position: Int
    private var peekBuffer: ByteBuffer
    private var peekBufferPosition: Int
    private var peekBufferLength: Int

    let syncActor: PlayerActor

    init(dataReader: DataReader, syncActor: PlayerActor, range: NSRange? = nil) {
        self.dataReader = dataReader
        self.position = range?.location ?? 0
        self.streamLength = range?.length

        let allocator = ByteBufferAllocator()
        self.scratchBuffer = allocator.buffer(capacity: .scratchSpaceSize)
        self.peekBuffer = allocator.buffer(capacity: .peekBufferSize)
        self.peekBufferPosition = 0
        self.peekBufferLength = 0
        self.syncActor = syncActor
    }

    @discardableResult
    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead == 0 {
            bytesRead = try await readFromUpstream(
                buffer: &buffer,
                offset: offset,
                length: length,
                bytesAlreadyRead: 0,
                allowEndOfInput: true,
                isolation: isolation
            )
        }
        commit(bytes: bytesRead)

        if bytesRead == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesRead)
        }
    }

    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool {
        syncActor.assertIsolated()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)

        while bytesRead < length && bytesRead != .resultEndOfInput {
            bytesRead = try await readFromUpstream(
                buffer: &buffer,
                offset: offset,
                length: length,
                bytesAlreadyRead: bytesRead,
                allowEndOfInput: allowEndOfInput,
                isolation: isolation
            )
        }

        commit(bytes: bytesRead)
        return bytesRead != .resultEndOfInput
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        var buffer = ByteBuffer()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead != 0 {
            if !readFromBuffer(buffer, to: allocation, offset: offset, length: bytesRead) {
                bytesRead = 0
            }
        }

        if bytesRead == 0 {
            bytesRead = try await readFromUpstream(
                allocation: allocation,
                offset: offset,
                length: length,
                bytesAlreadyRead: 0,
                allowEndOfInput: true,
                isolation: isolation
            )
        }
        commit(bytes: bytesRead)

        if bytesRead == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesRead)
        }
    }

    func readFully(allocation: Allocation, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool {
        syncActor.assertIsolated()
        var buffer = ByteBuffer()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead != 0 {
            if !readFromBuffer(buffer, to: allocation, offset: offset, length: bytesRead) {
                bytesRead = 0
            }
        }

        while bytesRead < length && bytesRead != .resultEndOfInput {
            bytesRead = try await readFromUpstream(
                allocation: allocation,
                offset: offset,
                length: length,
                bytesAlreadyRead: bytesRead,
                allowEndOfInput: allowEndOfInput,
                isolation: isolation
            )
        }

        commit(bytes: bytesRead)
        return bytesRead != .resultEndOfInput
    }

    func skip(length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        var bytesSkipped = skipFromPeekBuffer(length: length)
        if bytesSkipped == 0 {
            bytesSkipped = try await readFromUpstream(
                buffer: &scratchBuffer,
                offset: .zero,
                length: min(length, peekBuffer.capacity),
                bytesAlreadyRead: .zero,
                allowEndOfInput: true,
                isolation: isolation
            )
        }

        commit(bytes: bytesSkipped)
        if bytesSkipped == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesSkipped)
        }
    }

    func skipFully(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool {
        syncActor.assertIsolated()
        var bytesSkipped = skipFromPeekBuffer(length: length)

        while bytesSkipped < length && bytesSkipped != .resultEndOfInput {
            let minLenght = min(length, bytesSkipped + scratchBuffer.capacity)
            bytesSkipped = try await readFromUpstream(
                buffer: &scratchBuffer,
                offset: -bytesSkipped,
                length: minLenght,
                bytesAlreadyRead: bytesSkipped,
                allowEndOfInput: allowEndOfInput,
                isolation: isolation
            )
        }

        commit(bytes: bytesSkipped)
        return bytesSkipped != .resultEndOfInput
    }

    func peek(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        let peekBufferRemainingBytes = peekBufferLength - peekBufferPosition
        var bytesPeeked: Int = 0

        if peekBufferRemainingBytes == 0 {
            bytesPeeked = try await readFromUpstream(
                buffer: &peekBuffer,
                offset: peekBufferPosition,
                length: length,
                bytesAlreadyRead: .zero,
                allowEndOfInput: true,
                isolation: isolation
            )

            if bytesPeeked == .resultEndOfInput {
                return .endOfInput
            }

            peekBufferLength += bytesPeeked
        } else {
            bytesPeeked = min(length, peekBufferRemainingBytes)
        }

        var buffer = buffer
        buffer.moveWriterIndex(to: offset)
        peekBuffer.moveReaderIndex(to: peekBufferPosition)
        guard var slice = peekBuffer.readSlice(length: bytesPeeked) else {
            return .endOfInput
        }

        buffer.writeBuffer(&slice)

        peekBufferPosition += bytesPeeked
        return .success(amount: bytesPeeked)
    }

    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool {
        if try await !advancePeekPosition(length: length, allowEndOfInput: allowEndOfInput, isolation: isolation) {
            return false
        }

        peekBuffer.moveReaderIndex(to: peekBufferPosition - length)
        guard var slice = peekBuffer.readSlice(length: length) else {
            return false
        }
        buffer.moveWriterIndex(to: offset)
        buffer.writeBuffer(&slice)

        return true
    }

    func advancePeekPosition(length: Int, allowEndOfInput: Bool, isolation: isolated any Actor) async throws -> Bool {
        syncActor.assertIsolated()
        var bytesPeeked = peekBufferLength - peekBufferPosition
        while bytesPeeked < length {
            bytesPeeked = try await readFromUpstream(
                buffer: &peekBuffer,
                offset: peekBufferPosition,
                length: length,
                bytesAlreadyRead: bytesPeeked,
                allowEndOfInput: allowEndOfInput,
                isolation: isolation
            )

            if bytesPeeked == .resultEndOfInput {
                return false
            }

            peekBufferLength = peekBufferPosition + bytesPeeked
        }

        peekBufferPosition += length
        return true
    }

    func resetPeekPosition(isolation: isolated any Actor) {
        syncActor.assertIsolated()
        peekBufferPosition = 0
        peekBuffer.moveReaderIndex(to: .zero)
    }

    func getPeekPosition(isolation: isolated any Actor) -> Int {
        syncActor.assertIsolated()
        return position + peekBufferPosition
    }

    func getPosition(isolation: isolated any Actor) -> Int {
        syncActor.assertIsolated()
        return position
    }

    func getLength(isolation: isolated any Actor) -> Int? {
        syncActor.assertIsolated()
        return streamLength
    }

    func set<ErrorType: Error>(retryPosition: Int, using error: ErrorType, isolation: isolated any Actor) throws(ErrorType) {
        self.position = retryPosition
        throw error
    }
}

private extension DefaltExtractorInput {
    private func skipFromPeekBuffer(length: Int) -> Int {
        let skipped = min(peekBufferLength, length)
        peekBuffer.moveReaderIndex(forwardBy: skipped)
        updatePeekBuffer(consumed: skipped)
        return skipped
    }

    private func readFromPeekBuffer(_ buffer: inout ByteBuffer, offset: Int, length: Int) -> Int {
        guard peekBufferLength > 0 else { return .zero }
        let peekBytes = min(peekBufferLength, length)

        guard var slice = peekBuffer.readSlice(length: peekBytes) else {
            return .zero
        }
        buffer.moveWriterIndex(to: offset)
        buffer.writeBuffer(&slice)
        updatePeekBuffer(consumed: peekBytes)

        return peekBytes
    }

    private func updatePeekBuffer(consumed: Int) {
        peekBufferLength -= consumed
        peekBufferPosition = 0
        peekBuffer.discardReadBytes()
    }

    private func readFromUpstream(
        buffer: inout ByteBuffer,
        offset: Int,
        length: Int,
        bytesAlreadyRead: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> Int {
        let result = try await dataReader.read(
            to: &buffer,
            offset: offset + bytesAlreadyRead,
            length: length - bytesAlreadyRead,
            isolation: isolation
        )

        switch result {
        case let .success(amount):
            return bytesAlreadyRead + amount
        case .endOfInput:
            if bytesAlreadyRead == 0, allowEndOfInput {
                return .resultEndOfInput
            }

            throw ErrorBuilder.init(errorDescription: "EndOfFileError")
            // TODO: throw EndOfFileError
//            fatalError()
        }
    }

    private func readFromUpstream(
        allocation: Allocation,
        offset: Int,
        length: Int,
        bytesAlreadyRead: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> Int {
        let result = try await dataReader.read(
            allocation: allocation,
            offset: offset,
            length: length,
            isolation: isolation
        )

        switch result {
        case let .success(amount):
            return bytesAlreadyRead + amount
        case .endOfInput:
            if bytesAlreadyRead == 0, allowEndOfInput {
                return .resultEndOfInput
            }

            // TODO: throw EndOfFileError
            fatalError()
        }
    }

    private func readFromBuffer(
        _ buffer: ByteBuffer,
        to allocation: Allocation,
        offset: Int,
        length: Int
    ) -> Bool {
        buffer.withUnsafeReadableBytes { buffer in
            allocation.writeBuffer(offset: offset, lenght: length, buffer: buffer)
            return true
        }
    }

    private func commit(bytes read: Int) {
        guard read != .resultEndOfInput else { return }
        position += read
    }
}

private extension Int {
    static let resultEndOfInput: Int = -1
    static let scratchSpaceSize: Int = 4096
    static let peekBufferSize: Int = 64 * 1024
}
