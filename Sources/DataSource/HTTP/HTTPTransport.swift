//
//  HTTPTransport.swift
//  SEPlayer
//
//  Created by tvrrp on 21.06.2026.
//

import Foundation
import SEPlayerCommon

public protocol HTTPTransport: AnyObject, Sendable {
    var rangeID: UUID { get }
    var dataSpec: DataSpec { get }

    func start() -> (
        eventStream: AsyncStream<TransportStatus>,
        sessionStream: AsyncStream<TransportEvent>
    )
    func cancel()
}

public protocol HTTPTransportFactory: Sendable {
    associatedtype Transport: HTTPTransport

    func makeTransport(
        dataSpec: DataSpec,
        rangeID: UUID
    ) -> Transport
}

public enum TransportEvent: Sendable {
    case responseReceived(_ response: HTTPURLResponse, _ contentLength: Int?)
    case bytesReceived(DispatchData, at: Int)
    case metricsReceived(URLSessionTaskMetrics)
}

public enum TransportStatus: Sendable {
    case pending
    case running(_ readLenght: Int?)
    case completed
    case cancelled
    case failed(any Error & Sendable)
}

public struct DefaultHTTPTransportFactory<SessionLoader: IPlayerSessionLoader>: HTTPTransportFactory {
    private let loadQueue: any Queue
    private let sessionLoader: SessionLoader

    public init(loadQueue: any Queue, sessionLoader: SessionLoader) {
        self.loadQueue = loadQueue
        self.sessionLoader = sessionLoader
    }

    public func makeTransport(
        dataSpec: DataSpec,
        rangeID: UUID,
    ) -> DefaultHTTPTransport<SessionLoader> {
        return DefaultHTTPTransport(
            rangeID: rangeID,
            dataSpec: dataSpec,
            sessionLoader: sessionLoader
        )
    }
}

public final class DefaultHTTPTransport<SessionLoader: IPlayerSessionLoader>: HTTPTransport, @unchecked Sendable {
    public let rangeID: UUID
    public let dataSpec: DataSpec

    private let sessionLoader: SessionLoader
    private let lock: UnfairLock

    private var eventContinuation: AsyncStream<TransportStatus>.Continuation?
    private var sessionContinuation: AsyncStream<TransportEvent>.Continuation?

    private var dataTask: URLSessionDataTask?
    private var currentOffset: Int
    private var bytesToRead: Int?
    private var bytesToSkip: Int

    init(
        rangeID: UUID,
        dataSpec: DataSpec,
        sessionLoader: SessionLoader
    ) {
        self.rangeID = rangeID
        self.dataSpec = dataSpec
        self.sessionLoader = sessionLoader
        lock = UnfairLock()

        currentOffset = dataSpec.position
        bytesToSkip = 0
    }

    public func start() -> (
        eventStream: AsyncStream<TransportStatus>,
        sessionStream: AsyncStream<TransportEvent>
    ) {
        print("🦃 START NEW LOAD, dataSpec = \(dataSpec)")
        let (eventStream, eventContinuation) = AsyncStream<TransportStatus>.makeStream()
        let (sessionStream, sessionContinuation) = AsyncStream<TransportEvent>.makeStream()
        self.eventContinuation = eventContinuation
        self.sessionContinuation = sessionContinuation

        let request = dataSpec.createURLRequest()
        dataTask = sessionLoader.createTask(request: request, delegate: self)
        dataTask?.resume()
        defer { eventContinuation.yield(.pending) }
        return (eventStream, sessionStream)
    }

    public func cancel() {
        lock.withLock {
            eventContinuation?.yield(.cancelled)
            eventContinuation?.finish()
            sessionContinuation?.finish()

            eventContinuation = nil
            sessionContinuation = nil
        }

        dataTask?.cancel()
    }

    private func finish(
        with error: Error?,
        _ eventContinuation: AsyncStream<TransportStatus>.Continuation,
        _ sessionContinuation: AsyncStream<TransportEvent>.Continuation
    ) {
        switch error {
        case is CancellationError:
            eventContinuation.yield(.cancelled)
            break
        case let .some(error):
            eventContinuation.yield(.failed(error))
        case .none:
            eventContinuation.yield(.completed)
        }

        eventContinuation.finish()
        sessionContinuation.finish()

        lock.withLock {
            self.eventContinuation = nil
            self.sessionContinuation = nil
        }
    }
}

extension DefaultHTTPTransport: PlayerSessionDelegate {
    public func didRecieveResponse(
        _ response: URLResponse,
        task: URLSessionTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let eventContinuation = lock.withLock({ eventContinuation }),
              let sessionContinuation = lock.withLock({ sessionContinuation }) else {
            completionHandler(.cancel); return
        }

        guard let response = response as? HTTPURLResponse else {
            finish(
                with: URLSessionDataSourceError(
                    failedURL: dataSpec.url,
                    errorReason: .cannotParseResponse
                ),
                eventContinuation,
                sessionContinuation
            )

            completionHandler(.cancel); return
        }

        let responseCode = response.statusCode
        if responseCode < 200 || responseCode > 299 {
            if responseCode == 416 {
                let documentSize = response.contentLength
                if dataSpec.position == documentSize {
                    sessionContinuation.yield(.responseReceived(response, dataSpec.length ?? .zero))
                    completionHandler(.allow)
                    return
                }
            }

            finish(
                with: URLSessionDataSourceError(
                    failedURL: dataSpec.url,
                    errorReason: .badServerResponse
                ),
                eventContinuation,
                sessionContinuation
            )

            completionHandler(.cancel); return
        }

        bytesToSkip = responseCode == 200 && dataSpec.position != 0 ? dataSpec.position : 0
        if let bytesToRead = dataSpec.length {
            self.bytesToRead = bytesToRead
        } else {
            if let contentLength = response.contentLength {
                bytesToRead = contentLength - bytesToSkip
            } else {
                bytesToRead = nil
            }
        }

        sessionContinuation.yield(.responseReceived(response, bytesToRead))
        completionHandler(.allow)
        eventContinuation.yield(.running(bytesToRead))
    }

    public func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask) {
        guard let sessionContinuation = lock.withLock({ sessionContinuation }) else {
            task.cancel()
            return
        }

        if bytesToSkip > 0 {
            if buffer.count <= bytesToSkip { bytesToSkip -= buffer.count; return }
            let chunk = buffer.subdata(in: bytesToSkip..<buffer.count)
            bytesToSkip = 0
            sessionContinuation.yield(.bytesReceived(chunk, at: currentOffset))
            currentOffset += chunk.count
            return
        }

        sessionContinuation.yield(.bytesReceived(buffer, at: currentOffset))
        currentOffset += buffer.count
    }

    public func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        guard let eventContinuation = lock.withLock({ eventContinuation }),
              let sessionContinuation = lock.withLock({ sessionContinuation }) else {
            return
        }

        if let error {
            let error = URLSessionDataSourceError(error: error as NSError)
            if error.errorReason == .cancelled {
                finish(with: CancellationError(), eventContinuation, sessionContinuation)
            } else {
                finish(with: error, eventContinuation, sessionContinuation)
            }

            return
        }

        finish(with: nil, eventContinuation, sessionContinuation)
    }

    public func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        guard let sessionContinuation = lock.withLock({ sessionContinuation }) else {
            return
        }

        sessionContinuation.yield(.metricsReceived(metrics))
    }
}
