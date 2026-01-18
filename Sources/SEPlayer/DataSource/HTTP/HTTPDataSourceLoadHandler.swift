//
//  HTTPDataSourceLoadHandler.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2025.
//

import Foundation

actor HTTPDataSourceLoadHandler {
    private let byteBufferAllocator: ByteBufferAllocator
    private var byteBuffer: ByteBuffer
    private var readContinuation: CheckedContinuation<Void, Error>?
    private var bytesRemaining = 0

    private let executor: PlayerExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(syncActor: PlayerActor) {
        self.executor = syncActor.executor
        byteBuffer = ByteBuffer()
        byteBufferAllocator = ByteBufferAllocator()
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) async throws -> DataReaderReadResult {
        guard bytesRemaining > 0 else { return .endOfInput }
        let readAmount = try await validateAvailableData(for: length)
        guard readAmount > 0 else { return .endOfInput }

        let data = try byteBuffer.readData(count: readAmount, byteTransferStrategy: .noCopy)
        buffer.moveWriterIndex(to: offset)
        buffer.writeBytes(data)

        bytesRemaining -= readAmount
        return .success(amount: readAmount)
    }

    func read(allocation: Allocation, offset: Int, length: Int) async throws -> DataReaderReadResult {
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
        byteBuffer.clear(minimumCapacity: size)
        bytesRemaining = 0
    }

    func didOpenConnection(with size: Int) {
        byteBuffer.reserveCapacity(size)
        bytesRemaining = size
    }

    func didCloseConnection(with error: Error?) {
        bytesRemaining = byteBuffer.readableBytes
        if let error {
            readContinuation?.resume(throwing: error)
        } else {
            readContinuation?.resume()
        }
        readContinuation = nil
    }

    func consumeData(data: Data) {
        byteBuffer.writeBytes(data)
        readContinuation?.resume()
        readContinuation = nil
    }

    func returnAvailable() -> ByteBuffer? {
        return byteBuffer.readableBytes > 0 ? byteBuffer : nil
    }

    private func validateAvailableData(for requestedSize: Int) async throws -> Int {
        let requestedSize = min(bytesRemaining, requestedSize)
        if byteBuffer.readableBytes >= requestedSize {
            return requestedSize
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.readContinuation = continuation
            }
        } onCancel: {
            Task { await cancelValidation() }
        }

        return min(byteBuffer.readableBytes, requestedSize)
    }

    private func cancelValidation() {
        let readContinuation = self.readContinuation
        self.readContinuation = nil
        readContinuation?.resume(throwing: CancellationError())
    }
}
