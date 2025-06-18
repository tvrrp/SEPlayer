//
//  HTTPDataSource2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.06.2025.
//

import Foundation.NSURLSession

final class DefautlHTTPDataSource: DataSource {
    let components: DataSourceOpaque

    var url: URL? { queue.sync { _url } }
    var urlResponse: HTTPURLResponse? { lock.withLock { _urlResponce } }

    let queue: Queue
    private let connectTimeout: TimeInterval
    private let readTimeout: TimeInterval
    private let networkLoader: IPlayerSessionLoader
    private let operation: ConditionVariable
    private let lock: NSLock

    private var currentDataSpec: DataSpec?
    private var currentTask: URLSessionDataTask?
    private var intermidateBuffer = ByteBuffer()

    private var _url: URL?
    private var _urlResponce: HTTPURLResponse?

    private var openResult: Result<HTTPURLResponse, Error>?
    private var loadError: Error?

    private var didStart = false
    private var isClosed = false
    private var didFinish = false
    private var bytesRemaining = 0
    private var currentConnectionTimeout: TimeInterval
    private var currentReadTimeout: TimeInterval

    init(
        queue: Queue,
        networkLoader: IPlayerSessionLoader,
        components: DataSourceOpaque? = nil,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 10
    ) {
        self.queue = queue
        self.components = components ?? DataSourceOpaque(isNetwork: true)
        self.networkLoader = networkLoader
        self.connectTimeout = 10
        self.readTimeout = 10
        operation = ConditionVariable()
        lock = NSLock()
        currentConnectionTimeout = Date().timeIntervalSince1970
        currentReadTimeout =  Date().timeIntervalSince1970
    }

    func open(dataSpec: DataSpec) throws -> Int {
        assert(queue.isCurrent())
        operation.close()
        currentDataSpec = dataSpec
        resetConnectTimeout()
        return try createConnection(with: dataSpec)
    }

    @discardableResult
    func close() -> ByteBuffer? {
        return lock.withLock {
            print("❌ close connection, dataSpec = \(currentDataSpec)")
            isClosed = true
            didFinish = false
            openResult = nil
            currentTask?.cancel()
            currentTask = nil
            currentDataSpec = nil
            let buffer = intermidateBuffer
            intermidateBuffer.clear()
            return buffer
        }
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        guard length > 0 else { return .success(amount: .zero) }
        assert(queue.isCurrent())
        lock.lock()

        guard bytesRemaining > 0 else {
            lock.unlock()
            return .endOfInput
        }

        if let loadError {
            throw loadError
        }

        if intermidateBuffer.readableBytes <= 0 {
            lock.unlock()
            operation.close()
            operation.block(timeout: readTimeout)
            lock.lock()

            if didFinish {
                bytesRemaining = 0
                lock.unlock()
                return .endOfInput
            }
        }

        let readAmount = min(intermidateBuffer.readableBytes, length)
        try readFully(to: &buffer, offset: offset, length: readAmount)
        lock.unlock()
        return .success(amount: readAmount)
    }

    func read(allocation: Allocation, offset: Int, length: Int) throws -> DataReaderReadResult {
        guard length > 0 else { return .success(amount: .zero) }
        assert(queue.isCurrent())
        lock.lock()

        guard bytesRemaining > 0 else {
            lock.unlock()
            return .endOfInput
        }

        if let loadError {
            throw loadError
        }

        if intermidateBuffer.readableBytes <= 0 {
            lock.unlock()
            operation.close()
            operation.block(timeout: readTimeout)
            lock.lock()

            if didFinish {
                bytesRemaining = 0
                lock.unlock()
                return .endOfInput
            }
        }

        let readAmount = min(intermidateBuffer.readableBytes, length)
        try readFully(to: allocation, offset: offset, length: readAmount)
        lock.unlock()
        return .success(amount: readAmount)
    }

    private func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int) throws {
        let data = try! intermidateBuffer.readData(count: length)
        buffer.moveWriterIndex(to: offset)
        buffer.writeBytes(data)
        bytesRemaining -= length
    }

    private func readFully(to allocation: Allocation, offset: Int, length: Int) throws {
        try! intermidateBuffer.readWithUnsafeReadableBytes { pointer in
            guard let baseAdress = pointer.baseAddress else { throw DataReaderError.endOfInput }
            memcpy(allocation.data.advanced(by: offset), baseAdress, length)
            return length
        }
        bytesRemaining -= length
    }
}

extension DefautlHTTPDataSource: PlayerSessionDelegate {
    private func createConnection(with dataSpec: DataSpec) throws -> Int {
        assert(queue.isCurrent())
        let request = dataSpec.createURLRequest()
        lock.withLock {
            didFinish = false
            isClosed = false
            intermidateBuffer.clear()
            intermidateBuffer.reserveCapacity(dataSpec.length)
        }

        print("✅ createConnection, dataSpec = \(dataSpec), \(request.allHTTPHeaderFields)")
        let task = networkLoader.createTask(request: request, delegate: self)
        task.resume()
        self.currentTask = task
        transferInitializing(source: self)

        let connectionOpened = blockUntilConnectTimeout()
        guard let openResult, connectionOpened else { throw DataReaderError.connectionNotOpened }

        switch openResult {
        case let .success(urlResponce):
            let contentLength = contentLength(from: urlResponce)
            lock.withLock {
                bytesRemaining = if let currentDataSpec, currentDataSpec.length > 0 {
                    currentDataSpec.length
                } else {
                    contentLength
                }
                didStart = true
            }
            return contentLength
        case let .failure(error):
            throw error
        }
    }

    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask) -> URLSession.ResponseDisposition {
        assert(!queue.isCurrent())
        guard lock.withLock({ !isClosed && currentTask == task }) else {
            return .cancel
        }
        guard let urlResponce = response as? HTTPURLResponse else {
            lock.withLock {
                openResult = .failure(DataReaderError.wrongURLResponce)
                isClosed = true
                operation.close()
            }
            return .cancel
        }

        lock.withLock {
            didStart = true
            openResult = .success(urlResponce)
            self._urlResponce = urlResponce
        }

        operation.open()
        return .allow
    }

    func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        assert(!queue.isCurrent())
        guard lock.withLock({ !isClosed && currentTask == task }) else {
            return
        }
        lock.lock()
        intermidateBuffer.writeBytes(buffer)
        lock.unlock()
        operation.open()
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        assert(!queue.isCurrent())
        transferEnded(source: self, metrics: metrics)
    }

    func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        assert(!queue.isCurrent())

        lock.withLock {
            guard !isClosed && currentTask == task else { return }

            if let error {
                if openResult == nil {
                    openResult = .failure(error)
                } else {
                    loadError = error
                }
            }
            isClosed = true
            currentTask = nil

            operation.open()
        }
    }
}

private extension DefautlHTTPDataSource {
    private func blockUntilConnectTimeout() -> Bool {
        assert(queue.isCurrent())
        var now = Date().timeIntervalSince1970
        var opened = false

        while !opened, now < currentConnectionTimeout {
            opened = operation.block(timeout: currentConnectionTimeout - now + 5)
            now = Date().timeIntervalSince1970
        }

        return opened
    }

    private func resetConnectTimeout() {
        currentConnectionTimeout = Date().addingTimeInterval(connectTimeout).timeIntervalSince1970
    }
}

private extension DefautlHTTPDataSource {
    func contentLength(from httpResponse: HTTPURLResponse) -> Int {
        httpResponse
            .value(forHeaderKey: "Content-Length")?
            .components(separatedBy: "/").last
            .flatMap(Int.init) ?? 0
    }
}

private extension HTTPURLResponse {
    func value(forHeaderKey key: String) -> String? {
        return allHeaderFields
            .first { $0.key.description.caseInsensitiveCompare(key) == .orderedSame }?
            .value as? String
    }
}
