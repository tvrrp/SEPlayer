//
//  PlayerSessionLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.06.2025.
//


import Foundation.NSURLSession
import SEPlayerCommon

public protocol IPlayerSessionLoader: Sendable {
    func createTask(request: URLRequest, delegate: any PlayerSessionDelegate) -> URLSessionDataTask
    /// Opens a connection to the host of `url` ahead of the requests that need it.
    func preconnect(to url: URL)
}

public extension IPlayerSessionLoader {
    func preconnect(to url: URL) {}
}

public protocol PlayerSessionDelegate: AnyObject {
    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask)
    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask)
    func didFinishTask(_ task: URLSessionTask, error: (any Error)?)
}

public final class PlayerSessionLoader: IPlayerSessionLoader, @unchecked Sendable {
    private let queue: OperationQueue
    private let session: URLSession
    private let impl = _DataLoader()

    private let handlers = NSMapTable<URLSessionTask, AnyObject>.weakToWeakObjects()

    /// - Parameter configuration: The configuration of the session. Its URL cache is not used: the player keeps what
    ///   it reads itself, and a response from the cache would read as a network faster than any, skewing the
    ///   bandwidth estimate.
    public init(configuration: URLSessionConfiguration = .default, queue: OperationQueue? = nil) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = queue ?? PlayerSessionLoader.createOperationQueue()
        self.queue = queue
        session = URLSession(
            configuration: configuration,
            delegate: impl,
            delegateQueue: queue
        )

        session.sessionDescription = "Player URLSession"
        if queue.maxConcurrentOperationCount != 1 {
            assertionFailure("OperationQueue passed to PlayerMediaSessionLoader has a maxConcurrentOperationCount != 1, which is prohibited!")
            queue.maxConcurrentOperationCount = 1
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func createTask(request: URLRequest, delegate: any PlayerSessionDelegate) -> URLSessionDataTask {
        var request = request
        // The player loads with HTTP range requests, and URLSession requires range requests to use
        // `reloadIgnoringLocalAndRemoteCacheData`.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return impl.createTask(session, request: request, delegate: delegate)
    }

    /// Opens a connection to the host of `url` with a `HEAD` request whose answer nobody reads.
    ///
    /// Over HTTP/1.1 each request in flight takes a connection of its own, and a new one costs the TCP and TLS
    /// handshakes: when the requests that follow come at once, as the playlists and segments of a start, the ones
    /// that find no idle connection wait for them. Opened ahead, while the first request is in flight, the connection
    /// is ready for them.
    public func preconnect(to url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        SELogger.debug(.http, "Opening a connection to \(url.host ?? "the host") ahead")
        impl.createTask(session, request: request, delegate: PreconnectDelegate()).resume()
    }

    private static func createOperationQueue() -> OperationQueue {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = SignalQueue(name: "com.seplayer.loader").queue
        return operationQueue
    }
}

private final class _DataLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var handlers = [URLSessionTask: any PlayerSessionDelegate]()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        SELogger.debug(.http, "Redirect \(response.statusCode) from \(response.url?.absoluteString ?? "") to \(request.url?.absoluteString ?? "")")
        completionHandler(request)
    }

    func createTask(
        _ session: URLSession,
        request: URLRequest,
        delegate: any PlayerSessionDelegate
    ) -> URLSessionDataTask {
        let dataTask = session.dataTask(with: request)

        session.delegateQueue.addOperation {
            self.handlers[dataTask] = delegate
        }

        return dataTask
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.useCredential, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handler = handlers[task] else { return }
        handlers[task] = nil
        if let error = error as? URLError, error.code != .cancelled {
            SELogger.warning(.http, "Request for \(task.originalRequest?.url?.lastPathComponent ?? "") failed: \(error.code.rawValue) \(error.localizedDescription)")
        }

        handler.didFinishTask(task, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let handler = handlers[task] else { return }

        handler.didFinishCollectingMetrics(metrics, task: task)
    }
}

extension _DataLoader {
    // Manually specifying the selector without conforming to `URLSessionDataDelegate` to avoid Data bridging
    @objc(URLSession:dataTask:didReceiveResponse:completionHandler:)
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handlers[dataTask] else {
            completionHandler(.cancel); return
        }

        handler.didRecieveResponse(response, task: dataTask, completionHandler: completionHandler)
    }

    // Manually specifying the selector without conforming to `URLSessionDataDelegate` to avoid Data bridging
    @objc(URLSession:dataTask:didReceiveData:)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: NSData) {
        guard let handler = handlers[dataTask] else {
            return
        }

        let buffer: DispatchData
        if let dispatchData = data as AnyObject as? __DispatchData {
            buffer = dispatchData as DispatchData
        } else {
            nonisolated(unsafe) let data = data.copy() as! NSData
            buffer = unsafe DispatchData(
                bytesNoCopy: UnsafeRawBufferPointer(start: data.bytes, count: data.count),
                deallocator: .custom(nil) {
                    withExtendedLifetime(data) {}
                }
            )
        }

        handler.didReciveBuffer(buffer, task: dataTask)
    }
}

/// Takes the answer of a preconnecting request, so it completes and leaves its connection idle for the next request.
private final class PreconnectDelegate: PlayerSessionDelegate {
    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask) {}
    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {}
    func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {}
}
