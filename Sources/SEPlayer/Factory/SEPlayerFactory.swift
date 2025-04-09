//
//  SEPlayerFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public final class SEPlayerFactory {
    private let sessionLoader: IPlayerSessionLoader

    public init(configuration: URLSessionConfiguration = .default) {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        self.sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
    }

    public func buildPlayer(identifier: UUID = UUID(), returnQueue: DispatchQueue = .main) -> SEPlayer {
        SEPlayer(
            identifier: identifier,
            returnQueue: SignalQueue(queue: returnQueue),
            sessionLoader: sessionLoader
        )
        
    }
}
