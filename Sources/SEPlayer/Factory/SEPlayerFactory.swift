//
//  SEPlayerFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public final class SEPlayerFactory {
    private let sessionLoader: IPlayerSessionLoader
    private let decoderFactory: SEDecoderFactory
    private let displayLink: DisplayLinkProvider

    public init(configuration: URLSessionConfiguration = .default) {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        self.sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
        self.decoderFactory = DefaultSEDecoderFactory()
        self.displayLink = CADisplayLinkProvider()

        registerDecoders()
    }

    public func buildPlayer(identifier: UUID = UUID(), returnQueue: DispatchQueue = .main) -> SEPlayer {
        let workQueue = SignalQueue(name: "com.SEPlayer.work_\(identifier)", qos: .userInitiated)
        let allocator = DefaultAllocator(queue: workQueue)
        let playerDependencies = SEPlayerStateDependencies(
            playerId: identifier,
            queue: workQueue,
            returnQueue: SignalQueue(queue: returnQueue),
            sessionLoader: sessionLoader,
            allocator: allocator,
            displayLink: displayLink
        )
        return SEPlayer(
            dependencies: playerDependencies,
            renderersFactory: DefaultRenderersFactory(decoderFactory: decoderFactory)
        )
    }

    private func registerDecoders() {
        decoderFactory.register(VideoToolboxDecoder.self) { queue, format in
            try VideoToolboxDecoder(queue: queue, formatDescription: format)
        }

        decoderFactory.register(AudioConverterDecoder.self) { queue, format in
            try AudioConverterDecoder(queue: queue, formatDescription: format)
        }
    }
}
