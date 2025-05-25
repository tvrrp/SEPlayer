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

    public func buildPlayer(identifier: UUID = UUID()) -> BaseSEPlayer {
        let workQueue = SignalQueue(name: "com.seplayer.work_\(identifier)", qos: .userInitiated)
        let loaderQueue = SignalQueue(name: "com.seplayer.loader_\(identifier)", qos: .userInitiated)

        let dataSourceFactory = DefaultDataSourceFactory(loaderQueue: loaderQueue, networkLoader: sessionLoader)
        let extractorsFactory = DefaultExtractorFactory(queue: loaderQueue)
        let mediaSourceFactory = DefaultMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory
        )

        return SEPlayerImpl(
            identifier: identifier,
            queue: workQueue,
            clock: CMClockGetHostTimeClock(),
            renderersFactory: DefaultRenderersFactory(decoderFactory: decoderFactory),
            displayLink: displayLink,
            trackSelector: DefaultTrackSelector(),
            loadControl: DefaultLoadControl(queue: workQueue),
            mediaSourceFactory: mediaSourceFactory
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
