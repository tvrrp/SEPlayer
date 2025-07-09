//
//  PlayerSessionLoader2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.06.2025.
//


import Foundation.NSURLSession

public protocol IPlayerSessionLoader {
    func createTask(request: URLRequest, delegate: PlayerSessionDelegate) -> URLSessionDataTask
}

public protocol PlayerSessionDelegate: AnyObject {
    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask) -> URLSession.ResponseDisposition
    func didReciveBuffer(_ buffer: Data, task: URLSessionTask)
    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask)
    func didFinishTask(_ task: URLSessionTask, error: Error?)
}

final class PlayerSessionLoader: IPlayerSessionLoader {
    private let queue: OperationQueue
    let session: URLSession
    private let impl = _DataLoader()

    private let handlers = NSMapTable<URLSessionTask, AnyObject>.weakToWeakObjects()

    init(configuration: URLSessionConfiguration = .default, queue: OperationQueue? = nil) {
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

    func createTask(request: URLRequest, delegate: PlayerSessionDelegate) -> URLSessionDataTask {
        impl.createTask(session, request: request, delegate: delegate)
    }

    private static func createOperationQueue() -> OperationQueue {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        return operationQueue
    }
}

private final class _DataLoader: NSObject, URLSessionDataDelegate {
    private var handlers = [URLSessionTask: PlayerSessionDelegate]()

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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable(URLSession.ResponseDisposition) -> Void) {
        guard let handler = handlers[dataTask] else {
            completionHandler(.cancel); return
        }

        completionHandler(handler.didRecieveResponse(response, task: dataTask))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handlers[dataTask] else {
            return
        }

        handler.didReciveBuffer(data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handler = handlers[task] else { return }

        handlers[task] = nil
        handler.didFinishTask(task, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let handler = handlers[task] else {
            return
        }

        handler.didFinishCollectingMetrics(metrics, task: task)
    }
}
