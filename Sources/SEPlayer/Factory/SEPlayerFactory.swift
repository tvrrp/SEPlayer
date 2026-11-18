//
//  SEPlayerFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMSync
import DataSource
import Extractor
import Foundation
import SEPlayerCommon

public final class SEPlayerFactory {
    private let sessionLoader: PlayerSessionLoader
    private let bandwidthMeter: BandwidthMeter
    private let audioSessionController: AudioSessionController
    private let clock: SEClock
    private let workQueue: Queue
    private let loaderQueue: Queue
    private let diskCache: DiskCache?
    /// Where the players read local files, and the memory they read them into.
    private let fileReadQueue: Queue
    private let fileMemoryPool: CMMemoryPool
    /// The memory of decrypted HLS segments: freed memory is kept for a while, for the next segments.
    private let decryptionMemoryPool: CMMemoryPool

    /// - Parameters:
    ///   - diskCache: Where the players keep loaded bytes of media that doesn't change, for playing it again without
    ///     the network; `nil` keeps them in memory only.
    ///   - audioSessionController: What sets up the app's audio session for the players: the app has one session, so
    ///     all players of the app share one controller.
    public init(
        configuration: URLSessionConfiguration = .default,
        diskCache: DiskCache? = nil,
        audioSessionController: AudioSessionController = .shared
    ) {
        self.diskCache = diskCache
        self.audioSessionController = audioSessionController
        fileReadQueue = SignalQueue(name: "com.seplayer.file", qos: .userInitiated)
        fileMemoryPool = CMMemoryPool()
        decryptionMemoryPool = CMMemoryPool(ageOutPeriod: 5)
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = SignalQueue(name: "com.seplayer.loader", qos: .userInitiated).queue // Queues.loaderQueue.queue
        operationQueue.maxConcurrentOperationCount = 1
        sessionLoader = PlayerSessionLoader(configuration: configuration, queue: operationQueue)
        bandwidthMeter = DefaultBandwidthMeter()
        clock = DefaultSEClock()
        workQueue = SignalQueue(name: "com.seplayer.work.shared", qos: .userInteractive)
        loaderQueue = SignalQueue(name: "com.seplayer.loader.shared", qos: .userInitiated)

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
        renderersFactory: RenderersFactory? = nil,
        trackSelector: TrackSelector? = nil,
        loadControl: LoadControl? = nil,
        bandwidthMeter: BandwidthMeter? = nil,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy? = nil
    ) throws -> SEPlayer {
        let workQueue = workQueue ?? self.workQueue
        let loaderQueue = loaderQueue ?? self.loaderQueue

        let playerLoaderActor = loaderQueue.playerActor()
        // A given factory serves every media source; otherwise each gets its own.
        let makeDataSourceFactory: () -> DataSourceFactory = if let dataSourceFactory {
            { dataSourceFactory }
        } else {
            { [sessionLoader, diskCache, fileReadQueue, fileMemoryPool] in
                DefaultDataSourceFactory(
                    syncActor: playerLoaderActor,
                    networkLoader: sessionLoader,
                    diskCache: diskCache,
                    fileReadQueue: fileReadQueue,
                    fileMemoryPool: fileMemoryPool
                )
            }
        }
        let extractorsFactory = extractorsFactory ?? DefaultExtractorFactory(queue: loaderQueue)
        let mediaSourceFactory = mediaSourceFactory ?? DefaultMediaSourceFactory(
            workQueue: workQueue,
            loaderQueue: loaderQueue,
            makeDataSourceFactory: makeDataSourceFactory,
            extractorsFactory: extractorsFactory,
            decryptionMemoryPool: decryptionMemoryPool,
            loadErrorHandlingPolicy: loadErrorHandlingPolicy ?? DefaultLoadErrorHandlingPolicy()
        )

        let renderersFactory = renderersFactory ?? DefaultRenderersFactory()
        // Each player selects its own tracks with its own parameters: a track selector is not shared.
        let trackSelector = trackSelector ?? DefaultTrackSelector(
            trackSelectionFactory: AdaptiveTrackSelection.Factory()
        )
        let bandwidthMeter = bandwidthMeter ?? self.bandwidthMeter
        // Each player decides about its own buffer: a load control is not shared.
        let loadControl = loadControl ?? DefaultLoadControl(
            queue: workQueue,
            bandwidthMeter: bandwidthMeter
        )

        return try SEPlayerImpl(
            identifier: identifier,
            workQueue: workQueue,
            clock: clock,
            renderersFactory: renderersFactory,
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory,
            audioSessionController: audioSessionController
        )
    }
}
