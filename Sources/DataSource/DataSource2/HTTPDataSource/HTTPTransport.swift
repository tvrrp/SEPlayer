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
    associatedtype Transport: HTTPTransport

    func makeTransport(
        dataSpec: DataSpec,
        rangeID: UUID,
        delegate: any TransportEventDelegate
    ) -> Transport
}

public protocol TransportEventDelegate: AnyObject {
    func transport(_ transport: any HTTPTransport, didChange status: TransportStatus)
    func transport(_ transport: any HTTPTransport, didRecieve response: HTTPURLResponse, contentLength: Int?)
    func transport(_ transport: any HTTPTransport, didRecieve bytes: DispatchData, offset: Int)
    func transport(_ transport: any HTTPTransport, didRecieve metrics: URLSessionTaskMetrics)
}

public enum TransportEvent: Sendable {
    case responseReceived(_ response: HTTPURLResponse, _ contentLength: Int?)
    case bytesReceived(DispatchData, at: Int)
    case metricsReceived(URLSessionTaskMetrics)
    case statusChanged(TransportStatus)
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
        delegate: any TransportEventDelegate
    ) -> DefaultHTTPTransport<SessionLoader> {
        return DefaultHTTPTransport(
            queue: loadQueue,
            rangeID: rangeID,
            dataSpec: dataSpec,
            sessionLoader: sessionLoader,
            delegate: delegate
        )
    }
}

public final class DefaultHTTPTransport<SessionLoader: IPlayerSessionLoader>: HTTPTransport, @unchecked Sendable {
    public let queue: any Queue
    public let rangeID: UUID
    public let dataSpec: DataSpec

    private let sessionLoader: SessionLoader
    private weak let delegate: (any TransportEventDelegate)?

    private var dataTask: URLSessionDataTask?
    private var currentOffset: Int
    private var bytesToRead: Int?
    private var bytesToSkip: Int = 0

    init(
        queue: any Queue,
        rangeID: UUID,
        dataSpec: DataSpec,
        sessionLoader: SessionLoader,
        delegate: any TransportEventDelegate
    ) {
        self.queue = queue
        self.rangeID = rangeID
        self.dataSpec = dataSpec
        self.sessionLoader = sessionLoader
        self.delegate = delegate

        currentOffset = dataSpec.position
    }

    public func start() {
        assert(queue.isCurrent())
        print("❤️ START with range = \(dataSpec.range2)")
        let request = dataSpec.createURLRequest()
        dataTask = sessionLoader.createTask(request: request, delegate: self)
        dataTask?.resume()
        delegate?.transport(self, didChange: .pending)
    }

    public func cancel() {
        assert(queue.isCurrent())
        dataTask?.cancel()
        dataTask = nil
    }
}

extension DefaultHTTPTransport: PlayerSessionDelegate {
    public func didRecieveResponse(
        _ response: URLResponse,
        task: URLSessionTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        assert(queue.isCurrent())
        guard let delegate else { return }
        guard let response = response as? HTTPURLResponse else {
            delegate.transport(self, didChange: .failed(
                URLSessionDataSourceError(
                    failedURL: dataSpec.url,
                    errorReason: .cannotParseResponse
                )
            ))

            completionHandler(.cancel); return
        }

        let responseCode = response.statusCode
        if responseCode < 200 || responseCode > 299 {
            if responseCode == 416 {
                let documentSize = response.contentLength
                if dataSpec.position == documentSize {
                    delegate.transport(self, didRecieve: response, contentLength: dataSpec.length ?? .zero)
                    completionHandler(.allow)
                    return
                }
            }

            delegate.transport(self, didChange: .failed(
                URLSessionDataSourceError(
                    failedURL: dataSpec.url,
                    errorReason: .badServerResponse
                )
            ))
            completionHandler(.cancel); return
        }

        bytesToSkip = responseCode == 200 && dataSpec.position != 0 ? dataSpec.position : 0
        if let bytesToRead = dataSpec.length {
            self.bytesToRead = bytesToRead
        } else {
            if let contentLength = response.contentLength2 {
                bytesToRead = contentLength - bytesToSkip
            } else {
                bytesToRead = nil
            }
        }

        delegate.transport(self, didRecieve: response, contentLength: bytesToRead)
        completionHandler(.allow)
        delegate.transport(self, didChange: .running(bytesToRead))
    }

    public func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask) {
        assert(queue.isCurrent())
        if bytesToSkip > 0 {
            bytesToSkip -= buffer.count
            return
        }

        delegate?.transport(self, didRecieve: buffer, offset: currentOffset)
        currentOffset += buffer.count
    }

    public func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        assert(queue.isCurrent())
        if let error {
            let error = URLSessionDataSourceError(error: error as NSError)
            if error.errorReason == .cancelled {
                delegate?.transport(self, didChange: .cancelled)
            } else {
                delegate?.transport(self, didChange: .failed(error))
            }

            return
        }

        delegate?.transport(self, didChange: .completed)
    }

    public func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        assert(queue.isCurrent())
        delegate?.transport(self, didRecieve: metrics)
    }
}
