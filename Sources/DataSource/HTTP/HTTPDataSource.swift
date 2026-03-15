//
//  HTTPDataSource2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.06.2025.
//

import Foundation.NSURLSession
import SEPlayerCommon

final class DefautlHTTPDataSource: DataSource, @unchecked Sendable {
    var url: URL?
    var urlResponse: HTTPURLResponse?
    let components: DataSourceOpaque

    let syncActor: PlayerActor
    private let networkLoader: IPlayerSessionLoader
    private let loadHandler: HTTPDataSourceLoadHandler

    private var currentDataSpec: DataSpec?
    private var currentTask: URLSessionDataTask?

    private var openTask: Task<HTTPURLResponse, Error>?
    private var openContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    init(
        syncActor: PlayerActor,
        networkLoader: IPlayerSessionLoader,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 10
    ) {
        components = DataSourceOpaque(isNetwork: true)
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.loadHandler = HTTPDataSourceLoadHandler(queue: syncActor.executor.queue)
    }

    @discardableResult
    func open(dataSpec: DataSpec, isolation: isolated any Actor = #isolation) async throws -> Int {
        assert(queue.isCurrent())
        url = dataSpec.url
        currentDataSpec = dataSpec
        return try await createConnection(with: dataSpec)
    }

    func close(isolation: isolated any Actor = #isolation) async throws -> ByteBuffer? {
        assert(queue.isCurrent())
        currentTask?.cancel()
        currentTask = nil
        openTask?.cancel()
        loadHandler.didCloseConnection(with: nil) // TODO: do we realy need that?
        currentTask = nil
        currentDataSpec = nil
        return loadHandler.returnAvailable()
    }

    func read(
        to buffer: inout ByteBuffer,
        offset: Int,
        length: Int,
        isolation: isolated any Actor = #isolation
    ) async throws -> DataReaderReadResult {
        try await loadHandler.read(to: &buffer, offset: offset, length: length)
    }

    func read(
        allocation: Allocation,
        offset: Int,
        length: Int,
        isolation: isolated any Actor = #isolation
    ) async throws -> DataReaderReadResult {
        try await loadHandler.read(allocation: allocation, offset: offset, length: length)
    }
}

extension DefautlHTTPDataSource {
    private func createConnection(
        with dataSpec: DataSpec,
        isolation: isolated any Actor = #isolation
    ) async throws -> Int {
        assert(queue.isCurrent())
        let request = dataSpec.createURLRequest()
        loadHandler.willOpenConnection(with: dataSpec.length)

        let task = networkLoader.createTask(request: request, delegate: self)
        self.currentTask = task

        let openTask = Task<HTTPURLResponse, Error> {
            try await withCheckedThrowingContinuation(isolation: syncActor) { continuation in
                self.openContinuation = continuation
                task.resume()
            }
        }
        self.openTask = openTask

        let urlResponse = try await openTask.value
        self.openTask = nil
        loadHandler.didOpenConnection(with: urlResponse.contentLength)
        self.urlResponse = urlResponse
        return urlResponse.contentLength
    }
}

extension DefautlHTTPDataSource: PlayerSessionDelegate {
    var queue: Queue { syncActor.executor.queue }

    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask, completionHandler: @escaping @Sendable(URLSession.ResponseDisposition) -> Void) {
        assert(queue.isCurrent())
        guard let response = response as? HTTPURLResponse else {
            openContinuation?.resume(throwing: URLSessionDataSourceError(failedURL: url, errorReason: .cannotParseResponse))
            openContinuation = nil
            completionHandler(.cancel); return
        }

        let responseCode = response.statusCode
        if responseCode < 200 || responseCode > 299 {
            // TODO: check for 416 out of range code
            openContinuation?.resume(throwing: URLSessionDataSourceError(failedURL: url, errorReason: .badServerResponse))
            openContinuation = nil
            completionHandler(.cancel); return
        }

        openContinuation?.resume(returning: response)
        openContinuation = nil

        completionHandler(.allow)
    }

    func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        assert(queue.isCurrent())
        loadHandler.consumeData(data: buffer)
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        assert(queue.isCurrent())
        transferEnded(source: self, metrics: metrics)
    }

    func didFinishTask(_ task: URLSessionTask, error: Error?) {
        assert(queue.isCurrent())
        if let error {
            let urlSessionError = URLSessionDataSourceError(error: error as NSError)
            if urlSessionError.errorReason == .cancelled {
                openContinuation?.resume(throwing: CancellationError())
                loadHandler.didCloseConnection(with: CancellationError())
            } else {
                loadHandler.didCloseConnection(with: urlSessionError)
                openContinuation?.resume(throwing: urlSessionError)
            }

            openContinuation = nil
            return
        }

        loadHandler.didCloseConnection(with: nil)
    }
}

private extension HTTPURLResponse {
    func value(forHeaderKey key: String) -> String? {
        return allHeaderFields
            .first { $0.key.description.caseInsensitiveCompare(key) == .orderedSame }?
            .value as? String
    }
}

extension HTTPURLResponse {
    var contentLength: Int {
        value(forHeaderKey: "Content-Length")?
            .components(separatedBy: "/").last
            .flatMap(Int.init) ?? 0
    }
}
