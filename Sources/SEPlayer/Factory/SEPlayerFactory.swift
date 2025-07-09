//
//  SEPlayerFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMSync
import Foundation

public final class SEPlayerFactory {
    private let sessionLoader: IPlayerSessionLoader
    private let decoderFactory: SEDecoderFactory
    private let displayLink: DisplayLinkProvider
    private let bandwidthMeter: BandwidthMeter
    private let clock: CMClock

    public init(configuration: URLSessionConfiguration = .default) {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        self.sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
        self.decoderFactory = DefaultSEDecoderFactory()
        self.displayLink = CADisplayLinkProvider()
        self.bandwidthMeter = DefaultBandwidthMeter()
        self.clock = CMClockGetHostTimeClock()

        registerDecoders()
    }

    public func buildQueue(name: String? = nil, qos: DispatchQoS = .userInitiated) -> Queue {
        SignalQueue(name: name, qos: qos)
    }

    public func buildDisplayLinkProvider() -> DisplayLinkProvider {
        displayLink
    }

    public func buildPlayer(
        identifier: UUID = UUID(),
        workQueue: Queue? = nil,
        loaderQueue: Queue? = nil,
        dataSourceFactory: DataSourceFactory? = nil,
        extractorsFactory: ExtractorsFactory? = nil,
        mediaSourceFactory: MediaSourceFactory? = nil,
    ) -> SEPlayer {
        let workQueue = workQueue ?? SignalQueue(name: "com.seplayer.work_\(identifier)", qos: .userInitiated)
        let loaderQueue = loaderQueue ?? SignalQueue(name: "com.seplayer.loader_\(identifier)", qos: .userInitiated)

        let dataSourceFactory = dataSourceFactory ?? DefaultDataSourceFactory(loaderQueue: loaderQueue, networkLoader: sessionLoader)
        let extractorsFactory = extractorsFactory ?? DefaultExtractorFactory(queue: loaderQueue)
        let mediaSourceFactory = mediaSourceFactory ?? DefaultMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory
        )
        let renderersFactory = DefaultRenderersFactory(decoderFactory: decoderFactory)
        let trackSelector = DefaultTrackSelector()
        let loadControl = DefaultLoadControl(queue: workQueue)

        return SEPlayerImpl(
            identifier: identifier,
            queue: workQueue,
            clock: clock,
            renderersFactory: renderersFactory,
            displayLink: displayLink,
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory
        )
    }

    private func registerDecoders() {
        decoderFactory.register(VideoToolboxDecoder.self) { queue, format in
            try! VideoToolboxDecoder(queue: queue, formatDescription: format)
        }

        decoderFactory.register(AudioConverterDecoder.self) { queue, format in
            try! AudioConverterDecoder(queue: queue, formatDescription: format)
        }
    }
}
