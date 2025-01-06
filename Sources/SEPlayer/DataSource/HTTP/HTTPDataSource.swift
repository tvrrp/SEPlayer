//
//  HTTPDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

final class DefautlHTTPDataSource: DataSource {
    let components: DataSourceOpaque

    var url: URL? { queue.sync { _url } }
    var urlResponce: HTTPURLResponse? { queue.sync { _urlResponce } }

    let queue: Queue
    private let networkLoader: IPlayerSessionLoader

    private var isClosed: Bool = false

    private var currentDataSpec: DataSpec?
    private var currentTask: URLSessionDataTask?
    private var intermidateBuffer = ByteBuffer()

    private var _url: URL?
    private var _urlResponce: HTTPURLResponse?

    private var openCompletion: ((Result<Int, Error>) -> Void)?
    private var requestedReadAmount: Int?
    private var readCompletion: ((Result<Int, Error>) -> Void)?

    init(queue: Queue, networkLoader: IPlayerSessionLoader, components: DataSourceOpaque? = nil) {
        self.queue = queue
        self.components = components ?? DataSourceOpaque(isNetwork: true)
        self.networkLoader = networkLoader
    }

    func open(dataSpec: DataSpec, completionQueue: Queue, completion: @escaping (Result<Int, any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { completionQueue.async { completion(.failure(CancellationError())) }; return }
            close()
            openCompletion = completion
            createConnection(with: dataSpec, completionQueue: completionQueue)
        }
    }

    @discardableResult
    func close() -> ByteBuffer? {
        queue.sync { [weak self] in
            guard let self else { return nil }
            let openCompletion = openCompletion
            let readCompletion = readCompletion
            self.openCompletion = nil
            self.readCompletion = nil

            openCompletion?(.failure(CancellationError()))
            readCompletion?(.failure(CancellationError()))

            isClosed = true
            currentTask?.cancel()
            currentTask = nil
            requestedReadAmount = nil
            let buffer = intermidateBuffer
            intermidateBuffer.clear()
            return buffer
        }
    }

    func read(to buffer: ByteBuffer, offset: Int, length: Int, completionQueue: Queue, completion: @escaping (Result<(ByteBuffer, Int), Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let currentDataSpec else {
                completionQueue.async { completion(.failure(DataReaderError.connectionNotOpened)) }; return
            }

            do {
                if intermidateBuffer.readableBytes >= length {
                    let buffer = try readFully(to: buffer, offset: offset, length: length)
                    completionQueue.async { completion(.success((buffer, length))) }; return
                } else {
                    let requestedReadAmount = min(length, currentDataSpec.range.length + 1 - intermidateBuffer.readerIndex)

                    if requestedReadAmount == intermidateBuffer.readableBytes {
                        let buffer = try readFully(to: buffer, offset: offset, length: requestedReadAmount)
                        completionQueue.async { completion(.success((buffer, requestedReadAmount))) }; return
                    }

                    self.requestedReadAmount = requestedReadAmount
                    readCompletion = { [weak self] result in
                        guard let self else { completionQueue.async { completion(.failure(CancellationError())) }; return }
                        do {
                            switch result {
                            case let .success(availableBytesCount):
                                let buffer = try self.readFully(to: buffer, offset: offset, length: availableBytesCount)
                                completionQueue.async { completion(.success((buffer, availableBytesCount))) }
                            case let .failure(error):
                                completionQueue.async { completion(.failure(error)) }
                            }
                        } catch {
                            completionQueue.async { completion(.failure(error)) }
                        }
                    }
                }
            } catch {
                completionQueue.async { completion(.failure(error)) }
            }
        }
    }

    func read(allocation: Allocation, offset: Int, length: Int, completionQueue: Queue, completion: @escaping (Result<(Int), any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let currentDataSpec else { completionQueue.async { completion(.failure(DataReaderError.connectionNotOpened)) }; return }

            do {
                if intermidateBuffer.readableBytes >= length {
                    try readFully(to: allocation, offset: offset, length: length)
                    completionQueue.async { completion(.success(length)) }
                } else {
                    let requestedReadAmount = min(length, currentDataSpec.range.length + 1 - intermidateBuffer.readerIndex)
                    if requestedReadAmount == intermidateBuffer.readableBytes {
                        try readFully(to: allocation, offset: offset, length: requestedReadAmount)
                        completionQueue.async { completion(.success(requestedReadAmount)) }; return
                    }

                    self.requestedReadAmount = requestedReadAmount
                    readCompletion = { [weak self] result in
                        guard let self else { completionQueue.async { completion(.failure(CancellationError())) }; return }
                        do {
                            switch result {
                            case let .success(availableBytesCount):
                                try self.readFully(to: allocation, offset: offset, length: availableBytesCount)
                                completionQueue.async { completion(.success((availableBytesCount))) }
                            case let .failure(error):
                                completionQueue.async { completion(.failure(error)) }
                            }
                        } catch {
                            completionQueue.async { completion(.failure(error)) }
                        }
                    }
                }
            } catch {
                completionQueue.async { completion(.failure(error)) }
            }
        }
    }

    private func readFully(to buffer: ByteBuffer, offset: Int, length: Int) throws -> ByteBuffer {
        let data = try intermidateBuffer.readData(count: length)
        var buffer = buffer
        buffer.moveWriterIndex(to: offset)
        buffer.writeBytes(data)
        return buffer
    }

    private func readFully(to buffer: Allocation, offset: Int, length: Int) throws {
//        let data = try intermidateBuffer.readData(count: length)
        try intermidateBuffer.readWithUnsafeReadableBytes { pointer in
            guard let baseAdress = pointer.baseAddress else { throw DataReaderError.endOfInput }
            try buffer.getData { buffer in
                guard let bufferBaseAdress = buffer.baseAddress else { throw DataReaderError.endOfInput }
                bufferBaseAdress
                    .advanced(by: offset)
                    .copyMemory(from: pointer.baseAddress!, byteCount: length)
            }
            return length
        }
//        buffer.getData { pointer in
//            data.copyBytes(
//                to: pointer
//                    .baseAddress!
//                    .advanced(by: offset)
//                    .assumingMemoryBound(to: UInt8.self),
//                count: length
//            )
//        }
    }
}

private extension DefautlHTTPDataSource {
    private func createConnection(with dataSpec: DataSpec, completionQueue: Queue) {
        assert(queue.isCurrent())
        let request = dataSpec.createURLRequest()
        intermidateBuffer.clear()
        intermidateBuffer.reserveCapacity(dataSpec.length)

        let task = networkLoader.createTask(
            request: request,
            didRecieveResponce: { [weak self] response, task in
                guard self?.currentTask == task else { return .cancel }
                return self?.didRecieveResponce(response, dataSpec: dataSpec, completionQueue: completionQueue) ?? .cancel
            },
            didReciveBuffer: { [weak self] buffer, task in
                guard self?.currentTask == task else { return }
                self?.didRecieveBuffer(buffer)
            },
            didFinishCollectingMetrics: { [weak self] metrics, bytesTransfered, task in
                guard self?.currentTask == task else { return }
                self?.didFinishCollectingMetrics(metrics)
            },
            completion: { [weak self] error, task in
                guard self?.currentTask == task else { return }
                self?.didCompleteTask(error: error)
            }
        )
        task.resume()
        self.currentTask = task
        transferInitializing(source: self)
    }

    func didRecieveResponce(_ response: URLResponse, dataSpec: DataSpec, completionQueue: Queue) -> URLSession.ResponseDisposition {
        assert(queue.isCurrent())
        let openCompletion = openCompletion
        self.openCompletion = nil

        guard let urlResponce = response as? HTTPURLResponse else {
            completionQueue.async { openCompletion?(.failure(DataReaderError.wrongURLResponce)) }
            return .cancel
        }

        self.currentDataSpec = dataSpec
        let contentLength = contentLength(from: urlResponce)
        completionQueue.async { openCompletion?(.success(contentLength)) }
        return .allow
    }

    func didRecieveBuffer(_ buffer: Data) {
        assert(queue.isCurrent())
        intermidateBuffer.writeBytes(buffer)

        if let requestedReadAmount, intermidateBuffer.readableBytes >= requestedReadAmount {
            let readCompletion = self.readCompletion
            self.readCompletion = nil
            readCompletion?(.success(requestedReadAmount))
            self.requestedReadAmount = nil
        }
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics) {
        assert(queue.isCurrent())
        transferEnded(source: self, metrics: metrics)
    }

    func didCompleteTask(error: Error?) {
        assert(queue.isCurrent())
        let readCompletion = readCompletion
        let openCompletion = openCompletion
        self.readCompletion = nil
        self.openCompletion = nil

        if let error {
            openCompletion?(.failure(error))
            readCompletion?(.failure(error))
        }

        currentTask = nil
        requestedReadAmount = nil
    }
}

private extension DefautlHTTPDataSource {
    private var availableReadLenght: Int? {
        if let currentDataSpec {
            return currentDataSpec.range.length + 1 - intermidateBuffer.readerIndex
        } else {
            return nil
        }
    }
}

private extension DefautlHTTPDataSource {
    func contentLength(from httpResponse: HTTPURLResponse) -> Int {
        httpResponse
            .value(forHeaderKey: "Content-Range")?
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
