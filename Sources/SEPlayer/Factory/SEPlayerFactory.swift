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
    private let bandwidthMeter: BandwidthMeter
    private let trackSelector: TrackSelector
    private let audioSessionManager: IAudioSessionManager
    private let loadControl: LoadControl
    private let clock: SEClock
    private let workQueue: Queue
    private let loaderQueue: Queue

    public init(configuration: URLSessionConfiguration = .default) {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
        bandwidthMeter = DefaultBandwidthMeter()
        clock = DefaultSEClock()
        audioSessionManager = AudioSessionManager.shared
        workQueue = SignalQueue(name: "com.seplayer.work.shared", qos: .userInitiated)
        loaderQueue = SignalQueue(name: "com.seplayer.loader.shared", qos: .userInitiated)
        trackSelector = DefaultTrackSelector(
            trackSelectionFactory: AdaptiveTrackSelection.Factory(clock: clock)
        )
        loadControl = DefaultLoadControl(queue: workQueue)

        Prewarmer.shared.prewarm()
    }

    public func buildQueue(name: String? = nil, qos: DispatchQoS = .userInitiated) -> Queue {
        SignalQueue(name: name, qos: qos)
    }

    public func buildPlayer(
        identifier: UUID = UUID(),
        workQueue: Queue? = nil,
        applicationQueue: Queue? = nil,
        loaderQueue: Queue? = nil,
        dataSourceFactory: DataSourceFactory? = nil,
        extractorsFactory: ExtractorsFactory? = nil,
        mediaSourceFactory: MediaSourceFactory? = nil,
        renderersFactory: RenderersFactory? = nil,
        trackSelector: TrackSelector? = nil,
        loadControl: LoadControl? = nil,
        bandwidthMeter: BandwidthMeter? = nil
    ) -> SEPlayer {
        let workQueue = workQueue ?? self.workQueue
        let loaderQueue = loaderQueue ?? self.loaderQueue

        let playerLoaderActor = loaderQueue.playerActor()
        let dataSourceFactory = dataSourceFactory ?? DefaultDataSourceFactory(syncActor: playerLoaderActor, networkLoader: sessionLoader)
        let extractorsFactory = extractorsFactory ?? DefaultExtractorFactory(queue: loaderQueue)
        let mediaSourceFactory = mediaSourceFactory ?? DefaultMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            dataSourceFactory: dataSourceFactory,
            extractorsFactory: extractorsFactory
        )

        let renderersFactory = renderersFactory ?? DefaultRenderersFactory()
        let trackSelector = trackSelector ?? self.trackSelector
        let loadControl = loadControl ?? self.loadControl

        return SEPlayerImpl(
            identifier: identifier,
            workQueue: workQueue,
            applicationQueue: applicationQueue ?? Queues.mainQueue,
            clock: clock,
            renderersFactory: renderersFactory,
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter ?? self.bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory,
            audioSessionManager: audioSessionManager
        )
    }
}
