//
//  PlayerSessionLoaderAsyncStreamProvider.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import Foundation

public struct PlayerSessionLoaderEvent {
    let event: EventType
    let task: URLSessionTask

    public enum EventType {
        case didRecieveResponse(response: HTTPURLResponse)
        case didRecieveBuffer(buffer: Data)
        case didFinishCollectingMetrics(metrics: URLSessionTaskMetrics)
    }
}

final class PlayerSessionLoaderAsyncStreamProvider: PlayerSessionDelegate {
    private var continuation: AsyncThrowingStream<PlayerSessionLoaderEvent, Error>.Continuation?

    func createStream(with task: URLSessionDataTask) -> AsyncThrowingStream<PlayerSessionLoaderEvent, Error> {
        return AsyncThrowingStream<PlayerSessionLoaderEvent, Error> { continuation in
            self.continuation = continuation
            task.resume()

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func didRecieveResponse(_ response: URLResponse, task: URLSessionTask) -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            return .cancel
        }

        continuation?.yield(
            PlayerSessionLoaderEvent(
                event: .didRecieveResponse(response: response),
                task: task
            )
        )
        return .allow
    }

    func didReciveBuffer(_ buffer: Data, task: URLSessionTask) {
        continuation?.yield(
            PlayerSessionLoaderEvent(
                event: .didRecieveBuffer(buffer: buffer),
                task: task
            )
        )
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        continuation?.yield(
            PlayerSessionLoaderEvent(
                event: .didFinishCollectingMetrics(metrics: metrics),
                task: task
            )
        )
    }

    func didFinishTask(_ task: URLSessionTask, error: Error?) {
        continuation?.finish(throwing: error)
    }
}
