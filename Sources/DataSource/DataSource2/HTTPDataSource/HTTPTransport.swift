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

    func start()
    func cancel()
}

public protocol HTTPTransportFactory: Sendable {
    func makeTransport(
        dataSpec: DataSpec,
        rangeID: UUID,
        eventSink: @escaping @Sendable (TransportEvent) -> Void
    ) -> HTTPTransport
}

public enum TransportEvent: Sendable {
    case responseReceived(HTTPURLResponse)
    case bytesReceived(Data, at: Int)
    case metricsReceived(URLSessionTaskMetrics)
    case statusChanged(TransportStatus)
}

public enum TransportStatus: Sendable {
    case pending
    case running(currentHead: Int)
    case completed
    case cancelled
    case failed(any Error & Sendable)
}

public struct DefaultHTTPTransportFactory: HTTPTransportFactory {
    private let loadQueue: Queue
    private let sessionLoader: IPlayerSessionLoader

    public init(loadQueue: Queue, sessionLoader: IPlayerSessionLoader) {
        self.loadQueue = loadQueue
        self.sessionLoader = sessionLoader
    }

    public func makeTransport(dataSpec: DataSpec, rangeID: UUID, eventSink: @escaping (TransportEvent) -> Void) -> any HTTPTransport {
        return DefaultHTTPTransport(
            queue: loadQueue,
            rangeID: rangeID,
            dataSpec: dataSpec,
            sessionLoader: sessionLoader,
            eventSink: eventSink
        )
    }
}

public final class DefaultHTTPTransport: HTTPTransport {
    public let queue: Queue
    public let rangeID: UUID
    public let dataSpec: DataSpec

    private let sessionLoader: IPlayerSessionLoader
    private let eventSink: (TransportEvent) -> Void

    private var dataTask: URLSessionDataTask?
    private var currentOffset: Int

    init(
        queue: Queue,
        rangeID: UUID,
        dataSpec: DataSpec,
        sessionLoader: IPlayerSessionLoader,
        eventSink: @escaping (TransportEvent) -> Void,
    ) {
        self.queue = queue
        self.rangeID = rangeID
        self.dataSpec = dataSpec
        self.sessionLoader = sessionLoader
        self.eventSink = eventSink

        currentOffset = dataSpec.offset
    }

    public func start() {
        let request = dataSpec.createURLRequest()
        dataTask = sessionLoader.createTask(request: request, delegate: self)
        dataTask?.resume()
        eventSink(.statusChanged(.pending))
    }

    public func cancel() {
        dataTask?.cancel()
        dataTask = nil
    }
}

extension DefaultHTTPTransport: PlayerSessionDelegate {
    public func didRecieveResponse(_ response: URLResponse, task: URLSessionTask, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        assert(queue.isCurrent())
        guard let response = response as? HTTPURLResponse else {
            eventSink(.statusChanged(.failed(
                URLSessionDataSourceError(failedURL: dataSpec.url, errorReason: .cannotParseResponse)
            )))
            completionHandler(.cancel); return
        }

        let responseCode = response.statusCode
        if responseCode < 200 || responseCode > 299 {
            // TODO: check for 416 out of range code
            eventSink(.statusChanged(.failed(
                URLSessionDataSourceError(failedURL: dataSpec.url, errorReason: .badServerResponse)
            )))
            completionHandler(.cancel); return
        }

        eventSink(.responseReceived(response))
        completionHandler(.allow)
    }

    public func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        assert(queue.isCurrent())
        eventSink(.bytesReceived(buffer, at: currentOffset))
        currentOffset += buffer.count
    }

    public func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        assert(queue.isCurrent())
        if let error {
            let error = URLSessionDataSourceError(error: error as NSError)
            if error.errorReason == .cancelled {
                eventSink(.statusChanged(.cancelled))
            } else {
                eventSink(.statusChanged(.failed(error)))
            }

            return
        }

        eventSink(.statusChanged(.completed))
    }

    public func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        assert(queue.isCurrent())
        eventSink(.metricsReceived(metrics))
    }
}
