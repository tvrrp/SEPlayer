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

    let queue: Queue

    init(dataReader: DataReader, queue: Queue, range: NSRange? = nil) {
        self.dataReader = dataReader
        self.position = range?.location ?? 0
        self.streamLength = range?.length

        let allocator = ByteBufferAllocator()
        self.scratchBuffer = allocator.buffer(capacity: .scratchSpaceSize)
        self.peekBuffer = allocator.buffer(capacity: .peekBufferSize)
        self.peekBufferPosition = 0
        self.peekBufferLength = 0
        self.queue = queue
    }

    @discardableResult
    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead == 0 {
            bytesRead = try readFromUpstream(
                buffer: &buffer,
                offset: offset,
                length: length,
                bytesAlreadyRead: 0,
                allowEndOfInput: true
            )
        }
        commit(bytes: bytesRead)

        if bytesRead == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesRead)
        }
    }

    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool {
        assert(queue.isCurrent())
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)

        while bytesRead < length && bytesRead != .resultEndOfInput {
            bytesRead = try readFromUpstream(
                buffer: &buffer,
                offset: offset,
                length: length,
                bytesAlreadyRead: bytesRead,
                allowEndOfInput: allowEndOfInput
            )
        }

        commit(bytes: bytesRead)
        return bytesRead != .resultEndOfInput
    }

    func read(allocation: Allocation, offset: Int, length: Int) throws -> DataReaderReadResult {
        var buffer = ByteBuffer()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead != 0 {
            if !readFromBuffer(buffer, to: allocation, offset: offset, length: bytesRead) {
                bytesRead = 0
            }
        }

        if bytesRead == 0 {
            bytesRead = try readFromUpstream(
                allocation: allocation,
                offset: offset,
                length: length,
                bytesAlreadyRead: 0,
                allowEndOfInput: true
            )
        }
        commit(bytes: bytesRead)

        if bytesRead == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesRead)
        }
    }

    func readFully(allocation: Allocation, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool {
        assert(queue.isCurrent())
        var buffer = ByteBuffer()
        var bytesRead = readFromPeekBuffer(&buffer, offset: offset, length: length)
        if bytesRead != 0 {
            if !readFromBuffer(buffer, to: allocation, offset: offset, length: bytesRead) {
                bytesRead = 0
            }
        }

        while bytesRead < length && bytesRead != .resultEndOfInput {
            bytesRead = try readFromUpstream(
                allocation: allocation,
                offset: offset,
                length: length,
                bytesAlreadyRead: bytesRead,
                allowEndOfInput: allowEndOfInput
            )
        }

        commit(bytes: bytesRead)
        return bytesRead != .resultEndOfInput
    }

    func skip(length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        var bytesSkipped = skipFromPeekBuffer(length: length)
        if bytesSkipped == 0 {
            bytesSkipped = try readFromUpstream(
                buffer: &scratchBuffer,
                offset: .zero,
                length: min(length, peekBuffer.capacity),
                bytesAlreadyRead: .zero,
                allowEndOfInput: true
            )
        }

        commit(bytes: bytesSkipped)
        if bytesSkipped == .resultEndOfInput {
            return .endOfInput
        } else {
            return .success(amount: bytesSkipped)
        }
    }

    func skipFully(length: Int, allowEndOfInput: Bool) throws -> Bool {
        assert(queue.isCurrent())
        var bytesSkipped = skipFromPeekBuffer(length: length)

        while bytesSkipped < length && bytesSkipped != .resultEndOfInput {
            let minLenght = min(length, bytesSkipped + scratchBuffer.capacity)
            bytesSkipped = try readFromUpstream(
                buffer: &scratchBuffer,
                offset: -bytesSkipped,
                length: minLenght,
                bytesAlreadyRead: bytesSkipped,
                allowEndOfInput: allowEndOfInput
            )
        }

        commit(bytes: bytesSkipped)
        return bytesSkipped != .resultEndOfInput
    }

    func peek(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        let peekBufferRemainingBytes = peekBufferLength - peekBufferPosition
        var bytesPeeked: Int = 0

        if peekBufferRemainingBytes == 0 {
            bytesPeeked = try readFromUpstream(
                buffer: &peekBuffer,
                offset: peekBufferPosition,
                length: length,
                bytesAlreadyRead: .zero,
                allowEndOfInput: true
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

    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowEndOfInput: Bool) throws -> Bool {
        if try !advancePeekPosition(length: length, allowEndOfInput: allowEndOfInput) {
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

    func advancePeekPosition(length: Int, allowEndOfInput: Bool) throws -> Bool {
        assert(queue.isCurrent())
        var bytesPeeked = peekBufferLength - peekBufferPosition
        while bytesPeeked < length {
            bytesPeeked = try readFromUpstream(
                buffer: &peekBuffer,
                offset: peekBufferPosition,
                length: length,
                bytesAlreadyRead: bytesPeeked,
                allowEndOfInput: allowEndOfInput
            )

            if bytesPeeked == .resultEndOfInput {
                return false
            }

            peekBufferLength = peekBufferPosition + bytesPeeked
        }

        peekBufferPosition += length
        return true
    }

    func resetPeekPosition() {
        assert(queue.isCurrent())
        peekBufferPosition = 0
        peekBuffer.moveReaderIndex(to: .zero)
    }

    func getPeekPosition() -> Int {
        assert(queue.isCurrent())
        return position + peekBufferPosition
    }

    func getPosition() -> Int {
        assert(queue.isCurrent())
        return position
    }

    func getLength() -> Int? {
        assert(queue.isCurrent())
        return streamLength
    }

    func set<E>(retryPosition: Int, using error: E) throws where E : Error {
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
        allowEndOfInput: Bool
    ) throws -> Int {
        let result = try dataReader.read(
            to: &buffer,
            offset: offset + bytesAlreadyRead,
            length: length - bytesAlreadyRead
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
        allowEndOfInput: Bool
    ) throws -> Int {
        let result = try dataReader.read(
            allocation: allocation,
            offset: offset,
            length: length
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
