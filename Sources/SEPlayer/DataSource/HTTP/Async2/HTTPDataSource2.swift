//
//  HTTPDataSource2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import Foundation

protocol DataReader2 {
    func read(
        to buffer: inout ByteBuffer,
        offset: Int,
        length: Int,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
    func read(
        allocation: inout Allocation,
        offset: Int,
        length: Int,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
}

protocol DataSource2: DataReader2 {
    @discardableResult func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int
    @discardableResult func close(isolation: isolated any Actor) async -> ByteBuffer?
}

actor PlayerActor {
    nonisolated let executor: PlayerExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(executor: PlayerExecutor) {
        self.executor = executor
    }

    func run<T: Sendable>(body: @Sendable (isolated any Actor) async throws -> T) async rethrows -> T {
        try await body(self)
    }
}

final class PlayerExecutor: SerialExecutor {
    private nonisolated let queue: Queue
    init(queue: Queue) { self.queue = queue }

    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

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

        let data = try byteBuffer.readData(count: length, byteTransferStrategy: .noCopy)
        buffer.moveWriterIndex(to: offset)
        buffer.writeBytes(data)

        bytesRemaining -= readAmount
        return .success(amount: readAmount)
    }

    func read(allocation: inout Allocation, offset: Int, length: Int) async throws -> DataReaderReadResult {
        guard bytesRemaining > 0 else { return .endOfInput }
        let readAmount = try await validateAvailableData(for: length)
        guard readAmount > 0 else { return .endOfInput }

        byteBuffer.readWithUnsafeReadableBytes { pointer in
            allocation.writeBuffer(offset: offset, lenght: length, buffer: pointer)
            return readAmount
        }

        bytesRemaining -= readAmount
        return .success(amount: readAmount)
    }

    func willOpenConnection(with size: Int) {
        byteBuffer.clear(minimumCapacity: size)
    }

    func didOpenConnection(with size: Int) {
        byteBuffer.reserveCapacity(size)
        bytesRemaining = size
    }

    func didCloseConnection(with error: Error?) {
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
        if byteBuffer.readableBytes >= requestedSize {
            return requestedSize
        }

        try await withCheckedThrowingContinuation { continuation in
            self.readContinuation = continuation
        }

        return min(byteBuffer.readableBytes, requestedSize)
    }
}

final class DefautlHTTPDataSource2: DataSource2, @unchecked Sendable {
    private let syncActor: PlayerActor
    private let networkLoader: IPlayerSessionLoader
    private let loadHandler: HTTPDataSourceLoadHandler

    private var currentDataSpec: DataSpec?
    private var currentTask: URLSessionDataTask?

//    private var _url: URL?
//    private var _urlResponce: HTTPURLResponse?

    private var openTask: Task<HTTPURLResponse, Error>?
    private var openContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    init(
        syncActor: PlayerActor,
        networkLoader: IPlayerSessionLoader,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 10
    ) {
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.loadHandler = HTTPDataSourceLoadHandler(syncActor: syncActor)
    }

    func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        syncActor.assertIsolated()
        currentDataSpec = dataSpec
        return try await createConnection(with: dataSpec)
    }

    func close(isolation: isolated any Actor) async -> ByteBuffer? {
        syncActor.assertIsolated()
        currentTask?.cancel()
        currentTask = nil
        openTask?.cancel()
        currentTask = nil
        currentDataSpec = nil
        return await loadHandler.returnAvailable()
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        try await loadHandler.read(to: &buffer, offset: offset, length: length)
    }

    func read(allocation: inout Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        try await loadHandler.read(allocation: &allocation, offset: offset, length: length)
    }
}

extension DefautlHTTPDataSource2 {
    private func createConnection(
        with dataSpec: DataSpec,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Int {
        syncActor.assertIsolated()
        let request = dataSpec.createURLRequest()
        await loadHandler.willOpenConnection(with: dataSpec.length)

        let task = networkLoader.createTask(request: request, delegate: self)
        self.currentTask = task

        let openTask = Task<HTTPURLResponse, Error> {
            defer { openContinuation = nil }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation(isolation: syncActor) { continuation in
                    self.openContinuation = continuation
                    task.resume()
                }
            } onCancel: {
                Task { await syncActor.run { _ in
                    openContinuation?.resume(throwing: CancellationError())
                }}
            }
        }
        self.openTask = openTask

        let urlResponse = try await openTask.value
        self.openTask = nil
        await loadHandler.didOpenConnection(with: urlResponse.contentLength)
        return urlResponse.contentLength
    }
}

extension DefautlHTTPDataSource2: PlayerSessionDelegate {
    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask) -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            Task { await syncActor.run { _ in
                openContinuation?.resume(throwing: DataReaderError.wrongURLResponce)
            }}
            return .cancel
        }

        Task { await syncActor.run { _ in openContinuation?.resume(returning: response) } }

        return .allow
    }

    func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        Task { await loadHandler.consumeData(data: buffer) }
    }

    func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        if let error, (error as NSError).code == NSURLErrorCancelled {
            Task {
                await syncActor.run { _ in openContinuation?.resume(throwing: CancellationError()) }
                await loadHandler.didCloseConnection(with: CancellationError())
            }
            return
        }

        Task { await loadHandler.didCloseConnection(with: error) }
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        
    }
}
