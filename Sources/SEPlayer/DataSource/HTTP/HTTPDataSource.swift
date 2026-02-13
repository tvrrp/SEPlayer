//
//  HTTPDataSource2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.06.2025.
//

import Foundation.NSURLSession

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
        self.loadHandler = HTTPDataSourceLoadHandler(syncActor: syncActor)
    }

    @discardableResult
    func open(dataSpec: DataSpec, isolation: isolated any Actor = #isolation) async throws -> Int {
        syncActor.assertIsolated()
        url = dataSpec.url
        currentDataSpec = dataSpec
        return try await createConnection(with: dataSpec)
    }

    func close(isolation: isolated any Actor = #isolation) async -> ByteBuffer? {
        syncActor.assertIsolated()
        currentTask?.cancel()
        currentTask = nil
        openTask?.cancel()
        currentTask = nil
        currentDataSpec = nil
        return await loadHandler.returnAvailable()
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor = #isolation) async throws -> DataReaderReadResult {
        try await loadHandler.read(to: &buffer, offset: offset, length: length)
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor = #isolation) async throws -> DataReaderReadResult {
        try await loadHandler.read(allocation: allocation, offset: offset, length: length)
    }
}

extension DefautlHTTPDataSource {
    private func createConnection(
        with dataSpec: DataSpec,
        isolation: isolated any Actor = #isolation
    ) async throws -> Int {
        syncActor.assertIsolated()
        let request = dataSpec.createURLRequest()
        await loadHandler.willOpenConnection(with: dataSpec.length)

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
        await loadHandler.didOpenConnection(with: urlResponse.contentLength)
        self.urlResponse = urlResponse
        return urlResponse.contentLength
    }
}

extension DefautlHTTPDataSource: PlayerSessionDelegate {
    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask, isolation: isolated PlayerActor) async -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            openContinuation?.resume(throwing: DataReaderError.wrongURLResponse)
            openContinuation = nil
            return .cancel
        }

        let responseCode = response.statusCode
        if responseCode < 200 || responseCode > 299 {
            // TODO: check for 416 out of range code
            openContinuation?.resume(throwing: DataReaderError.wrongResponseStatusCode)
            openContinuation = nil
            return .cancel
        }

        openContinuation?.resume(returning: response)
        openContinuation = nil

        return .allow
    }

    func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        syncActor.executor.queue.async {
            self.loadHandler.assumeIsolated { handler in
                handler.consumeData(data: buffer)
            }
        }
    }

    func didFinishTask(_ task: URLSessionTask, error: Error?, isolation: isolated PlayerActor) async {
        if let error, (error as NSError).code == NSURLErrorCancelled {
            openContinuation?.resume(throwing: CancellationError())
            openContinuation = nil
            await loadHandler.didCloseConnection(with: CancellationError())
            return
        }

        if let error {
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        }

        await loadHandler.didCloseConnection(with: error)
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask, isolation: isolated PlayerActor) async {
        transferEnded(source: self, metrics: metrics)
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
