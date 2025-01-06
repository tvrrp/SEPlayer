//
//  PlayerSessionLoader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

protocol IPlayerSessionLoader {
    func createTask(
        request: URLRequest,
        didRecieveResponce: @escaping (URLResponse, URLSessionTask) -> URLSession.ResponseDisposition,
        didReciveBuffer: @escaping (Data, URLSessionTask) -> Void,
        didFinishCollectingMetrics: @escaping (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void,
        completion: @escaping (Error?, URLSessionTask) -> Void
    ) -> URLSessionDataTask
}

final class PlayerSessionLoader: IPlayerSessionLoader {
    private let queue: OperationQueue
    let session: URLSession
    private let impl = _DataLoader()

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
            // It's better to crash here because we would eventually crash at runtime with EXC_BAD_ACCESS
            // while mutating _DataLoader's handlers dictionary from a concurrent queue.
            fatalError("OperationQueue passed to PlayerMediaSessionLoader has a maxConcurrentOperationCount != 1, which is prohibited!")
        }
    }

    func createTask(
        request: URLRequest,
        didRecieveResponce: @escaping (URLResponse, URLSessionTask) -> URLSession.ResponseDisposition,
        didReciveBuffer: @escaping (Data, URLSessionTask) -> Void,
        didFinishCollectingMetrics: @escaping (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void,
        completion: @escaping ((any Error)?, URLSessionTask) -> Void
    ) -> URLSessionDataTask {
        impl.createTask(
            session, request: request,
            response: didRecieveResponce,
            buffer: didReciveBuffer,
            metrics: didFinishCollectingMetrics,
            completion: completion
        )
    }

    private static func createOperationQueue() -> OperationQueue {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        return operationQueue
    }
}

private final class _DataLoader: NSObject, URLSessionDataDelegate, URLSessionStreamDelegate {
    private var delegateHandlers = [URLSessionTask: SessionHandler]()
    private var metricsHandlers = [URLSessionTask: MetricsHandler]()

    func createTask(
        _ session: URLSession,
        request: URLRequest,
        metrics: @escaping (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void,
        completion: @escaping (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        let metricsHandler = MetricsHandler(didFinishCollectingMetrics: metrics)
        let dataTask = session.dataTask(with: request) { data, response, error in
            session.delegateQueue.addOperation {
                completion(data, response, error)
            }
        }

        session.delegateQueue.addOperation {
            self.metricsHandlers[dataTask] = metricsHandler
        }

        dataTask.taskDescription = "Player loading task with completion"
        return dataTask
    }

    func createTask(
        _ session: URLSession,
        request: URLRequest,
        response: @escaping (URLResponse, URLSessionTask) -> URLSession.ResponseDisposition,
        buffer: @escaping (Data, URLSessionTask) -> Void,
        metrics: @escaping (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void,
        completion: @escaping (Error?, URLSessionTask) -> Void
    ) -> URLSessionDataTask {
        let delegateHandler = SessionHandler(didRecieveResponse: response, didReciveBuffer: buffer, completion: completion)
        let metricsHandler = MetricsHandler(didFinishCollectingMetrics: metrics)
        let dataTask = session.dataTask(with: request)

        session.delegateQueue.addOperation {
            self.delegateHandlers[dataTask] = delegateHandler
            self.metricsHandlers[dataTask] = metricsHandler
        }

        dataTask.taskDescription = "Player loading task with delegate"
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
        guard let handler = delegateHandlers[dataTask] else {
            completionHandler(.cancel); return
        }

        completionHandler(handler.didRecieveResponse(response, dataTask))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = delegateHandlers[dataTask] else {
            return
        }

        handler.didReciveBuffer(data, dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handler = delegateHandlers[task] else { return }

        delegateHandlers[task] = nil
        handler.completion(error, task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let handler = metricsHandlers[task] else {
            return
        }

        metricsHandlers[task] = nil
        handler.didFinishCollectingMetrics(metrics, task.countOfBytesReceived, task)
    }
}

extension _DataLoader {
    private final class SessionHandler {
        let didRecieveResponse: (URLResponse, URLSessionTask) -> URLSession.ResponseDisposition
        let didReciveBuffer: (Data, URLSessionTask) -> Void
        let completion: (Error?, URLSessionTask) -> Void

        init(
            didRecieveResponse: @escaping (URLResponse, URLSessionTask) -> URLSession.ResponseDisposition,
            didReciveBuffer: @escaping (Data, URLSessionTask) -> Void,
            completion: @escaping (Error?, URLSessionTask) -> Void
        ) {
            self.didRecieveResponse = didRecieveResponse
            self.didReciveBuffer = didReciveBuffer
            self.completion = completion
        }
    }

    private final class MetricsHandler {
        let didFinishCollectingMetrics: (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void

        init(didFinishCollectingMetrics: @escaping (URLSessionTaskMetrics, Int64, URLSessionTask) -> Void) {
            self.didFinishCollectingMetrics = didFinishCollectingMetrics
        }
    }
}
