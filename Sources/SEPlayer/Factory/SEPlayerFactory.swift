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
    private let decodersFactory: SEDecoderFactory
    private let bandwidthMeter: BandwidthMeter
    private let audioSessionManager: IAudioSessionManager
    private let clock: SEClock

    public init(configuration: URLSessionConfiguration = .default) {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        self.sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
        self.decodersFactory = DefaultSEDecoderFactory()
        self.bandwidthMeter = DefaultBandwidthMeter()
        self.clock = DefaultSEClock()
        audioSessionManager = AudioSessionManager.shared

        registerDefaultDecoders(factory: decodersFactory)
        Prewarmer.shared.prewarm()
    }

    public func buildQueue(name: String? = nil, qos: DispatchQoS = .userInitiated) -> Queue {
        SignalQueue(name: name, qos: qos)
    }

    public func buildPlayer(
        identifier: UUID = UUID(),
        workQueue: Queue? = nil,
        loaderQueue: Queue? = nil,
        dataSourceFactory: DataSourceFactory? = nil,
        extractorsFactory: ExtractorsFactory? = nil,
        mediaSourceFactory: MediaSourceFactory? = nil,
        decodersFactory: SEDecoderFactory? = nil,
        renderersFactory: RenderersFactory? = nil,
        trackSelector: TrackSelector? = nil,
        loadControl: LoadControl? = nil,
        bandwidthMeter: BandwidthMeter? = nil
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
        let decodersFactory = decodersFactory ?? self.decodersFactory
        let renderersFactory = renderersFactory ?? DefaultRenderersFactory(decoderFactory: decodersFactory)
        let trackSelector = trackSelector ?? DefaultTrackSelector()
        let loadControl = loadControl ?? DefaultLoadControl(queue: workQueue)

        return SEPlayerImpl(
            identifier: identifier,
            queue: workQueue,
            clock: clock,
            renderersFactory: renderersFactory,
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter ?? self.bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory,
            audioSessionManager: audioSessionManager
        )
    }

    public func registerDefaultDecoders(factory: SEDecoderFactory) {
        factory.register(VideoToolboxDecoder.self) { queue, format in
            try VideoToolboxDecoder(queue: queue, format: format)
        }

        factory.register(AudioConverterDecoder.self) { queue, format in
            try AudioConverterDecoder(queue: queue, format: format)
        }

//        decoderFactory.register(OpusDecoder.self) { queue, format in
//            try OpusDecoder(queue: queue, format: format)
//        }
    }
}
