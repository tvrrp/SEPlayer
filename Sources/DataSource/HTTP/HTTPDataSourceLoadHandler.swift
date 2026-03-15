//
//  HTTPDataSourceLoadHandler.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2025.
//

import Foundation
import SEPlayerCommon

final class HTTPDataSourceLoadHandler {
    private let queue: Queue
    private var byteBuffer: ByteBuffer
    private var readContinuation: CheckedContinuation<Void, Error>?
    private var bytesRemaining = 0

    init(queue: Queue) {
        self.queue = queue
        byteBuffer = ByteBuffer()
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor = #isolation) async throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        guard bytesRemaining > 0 else { return .endOfInput }
        let readAmount = try await validateAvailableData(for: length)
        guard readAmount > 0 else { return .endOfInput }

        let data = try byteBuffer.readData(count: readAmount, byteTransferStrategy: .noCopy)
        buffer.moveWriterIndex(to: offset)
        buffer.writeBytes(data)

        bytesRemaining -= readAmount
        return .success(amount: readAmount)
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor = #isolation) async throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        guard bytesRemaining > 0 else { return .endOfInput }
        let readAmount = try await validateAvailableData(for: length)
        guard readAmount > 0 else { return .endOfInput }

        byteBuffer.readWithUnsafeReadableBytes { pointer in
            allocation.writeBuffer(offset: offset, lenght: readAmount, buffer: pointer)
            return readAmount
        }

        bytesRemaining -= readAmount
        return .success(amount: readAmount)
    }

    func willOpenConnection(with size: Int) {
        assert(queue.isCurrent())
        byteBuffer.clear(minimumCapacity: size)
        bytesRemaining = 0
    }

    func didOpenConnection(with size: Int) {
        assert(queue.isCurrent())
        byteBuffer.reserveCapacity(size)
        bytesRemaining = size
    }

    func didCloseConnection(with error: Error?) {
        assert(queue.isCurrent())
        bytesRemaining = byteBuffer.readableBytes
        if let error {
            readContinuation?.resume(throwing: error)
        } else {
            readContinuation?.resume()
        }
        readContinuation = nil
    }

    func consumeData(data: Data) {
        assert(queue.isCurrent())
        byteBuffer.writeBytes(data)
        readContinuation?.resume()
        readContinuation = nil
    }

    func returnAvailable() -> ByteBuffer? {
        assert(queue.isCurrent())
        return byteBuffer.readableBytes > 0 ? byteBuffer : nil
    }

    private func validateAvailableData(for requestedSize: Int, isolation: isolated any Actor = #isolation) async throws -> Int {
        assert(queue.isCurrent())
        let requestedSize = min(bytesRemaining, requestedSize)
        if byteBuffer.readableBytes >= requestedSize {
            return requestedSize
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.readContinuation = continuation
            }
        } onCancel: {
            queue.async { self.cancelValidation() }
        }

        return min(byteBuffer.readableBytes, requestedSize)
    }

    private func cancelValidation() {
        assert(queue.isCurrent())
        let readContinuation = self.readContinuation
        self.readContinuation = nil
        readContinuation?.resume(throwing: CancellationError())
    }
}
