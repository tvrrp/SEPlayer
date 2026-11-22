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

/// Makes players that share what can be shared: the queues, the network session and the disk cache, the bandwidth
/// estimate, and the factories, which hold no state of a player.
///
/// What holds the state of one player, its track selector, load control and live speed control, is made for each
/// player by ``buildPlayer(identifier:trackSelector:loadControl:livePlaybackSpeedControl:)``.
public final class SEPlayerFactory {
    private let sessionLoader: IPlayerSessionLoader
    private let bandwidthMeter: BandwidthMeter
    private let audioSessionController: AudioSessionController
    private let clock: SEClock
    private let workQueue: Queue
    private let loaderQueue: Queue
    private let diskCache: DiskCache?
    /// Where the players read local files, and the memory they read them into.
    private let fileReadQueue: Queue
    private let fileMemoryPool: CMMemoryPool
    private let renderersFactory: RenderersFactory
    private let mediaSourceFactory: MediaSourceFactory

    /// - Parameters:
    ///   - workQueue: The queue the players run on.
    ///   - loaderQueue: The queue the players load and extract media on.
    ///   - fileReadQueue: The queue local files are read on.
    ///   - sessionLoader: Loads over the network; by default, a `URLSession` set up for streaming.
    ///   - diskCache: Where the players keep loaded bytes of media that doesn't change, for playing it again without
    ///     the network; `nil` keeps them in memory only.
    ///   - bandwidthMeter: Estimates the bandwidth the players share.
    ///   - audioSessionController: What sets up the app's audio session for the players: the app has one session, so
    ///     all players of the app share one controller.
    ///   - clock: The clock of the players; by default, the system clock.
    ///   - renderersFactory: Makes the renderers of each player.
    ///   - dataSourceFactory: Loads the media of every media source; by default, each media source gets its own data
    ///     source factory, which reads through the session and the disk cache.
    ///   - extractorsFactory: Makes the extractors of progressive media.
    ///   - subtitleParserFactory: Parses subtitles into cues as they load.
    ///   - loadErrorHandlingPolicy: Decides about retries and fallbacks when loads fail.
    ///   - mediaSourceFactory: Makes the media sources of the items; by default, HLS and progressive ones made with the
    ///     factories and the policy above.
    public init(
        workQueue: Queue? = nil,
        loaderQueue: Queue? = nil,
        fileReadQueue: Queue? = nil,
        sessionLoader: IPlayerSessionLoader? = nil,
        diskCache: DiskCache? = DiskCache(),
        bandwidthMeter: BandwidthMeter? = nil,
        audioSessionController: AudioSessionController = .shared,
        clock: SEClock? = nil,
        renderersFactory: RenderersFactory = DefaultRenderersFactory(),
        dataSourceFactory: DataSourceFactory? = nil,
        extractorsFactory: ExtractorsFactory? = nil,
        subtitleParserFactory: SubtitleParserFactory = DefaultSubtitleParserFactory(),
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy(),
        mediaSourceFactory: MediaSourceFactory? = nil
    ) {
        let workQueue = workQueue ?? SignalQueue(name: "com.seplayer.work.shared", qos: .userInteractive)
        let loaderQueue = loaderQueue ?? SignalQueue(name: "com.seplayer.loader.shared", qos: .userInitiated)
        let fileReadQueue = fileReadQueue ?? SignalQueue(name: "com.seplayer.file", qos: .userInitiated)
        let fileMemoryPool = CMMemoryPool()
        let sessionLoader = sessionLoader ?? Self.makeSessionLoader()

        self.workQueue = workQueue
        self.loaderQueue = loaderQueue
        self.fileReadQueue = fileReadQueue
        self.fileMemoryPool = fileMemoryPool
        self.sessionLoader = sessionLoader
        self.diskCache = diskCache
        self.bandwidthMeter = bandwidthMeter ?? DefaultBandwidthMeter()
        self.audioSessionController = audioSessionController
        self.clock = clock ?? DefaultSEClock.shared
        self.renderersFactory = renderersFactory

        // A given data source factory serves every media source; otherwise each gets its own.
        let makeDataSourceFactory: () -> DataSourceFactory = if let dataSourceFactory {
            { dataSourceFactory }
        } else {
            {
                Self.makeDataSourceFactory(
                    loaderQueue: loaderQueue,
                    sessionLoader: sessionLoader,
                    diskCache: diskCache,
                    fileReadQueue: fileReadQueue,
                    fileMemoryPool: fileMemoryPool
                )
            }
        }
        self.mediaSourceFactory = mediaSourceFactory ?? DefaultMediaSourceFactory(
            hlsMediaSourceFactory: HlsMediaSourceFactory(
                workQueue: workQueue,
                loaderQueue: loaderQueue,
                makeDataSourceFactory: makeDataSourceFactory,
                subtitleParserFactory: subtitleParserFactory,
                // Freed memory is kept for a while, for the next segments.
                decryptionMemoryPool: CMMemoryPool(ageOutPeriod: 5),
                loadErrorHandlingPolicy: loadErrorHandlingPolicy
            ),
            progressiveMediaSourceFactory: ProgressiveMediaSourceFactory(
                workQueue: workQueue,
                loaderQueue: loaderQueue,
                makeDataSourceFactory: makeDataSourceFactory,
                extractorsFactory: extractorsFactory
                    ?? DefaultExtractorFactory(queue: loaderQueue, subtitleParserFactory: subtitleParserFactory),
                loadErrorHandlingPolicy: loadErrorHandlingPolicy
            )
        )

        Prewarmer.shared.prewarm()
    }

    public static func buildQueue(name: String? = nil, qos: DispatchQoS = .userInitiated) -> Queue {
        SignalQueue(name: name, qos: qos)
    }

    /// The data source factory the players' media sources use by default: HTTP through the factory's session, local
    /// files, and the disk cache. Each call makes a new one, whose data sources share HTTP resources only with each
    /// other.
    public func makeDataSourceFactory() -> DataSourceFactory {
        Self.makeDataSourceFactory(
            loaderQueue: loaderQueue,
            sessionLoader: sessionLoader,
            diskCache: diskCache,
            fileReadQueue: fileReadQueue,
            fileMemoryPool: fileMemoryPool
        )
    }

    /// Makes a player.
    ///
    /// - Parameters:
    ///   - identifier: The identifier of the player.
    ///   - trackSelector: Selects the tracks the player plays; by default, adaptive selection.
    ///   - loadControl: Decides when the player loads and starts playing; by default, a ``DefaultLoadControl`` with
    ///     the factory's bandwidth meter.
    ///   - livePlaybackSpeedControl: Adjusts the speed of live playback to keep the target live offset.
    public func buildPlayer(
        identifier: UUID = UUID(),
        trackSelector: TrackSelector? = nil,
        loadControl: LoadControl? = nil,
        livePlaybackSpeedControl: LivePlaybackSpeedControl? = nil
    ) throws -> SEPlayer {
        let trackSelector = trackSelector ?? DefaultTrackSelector(
            trackSelectionFactory: AdaptiveTrackSelection.Factory()
        )
        let loadControl = loadControl ?? DefaultLoadControl(queue: workQueue, bandwidthMeter: bandwidthMeter)

        return try SEPlayerImpl(
            identifier: identifier,
            workQueue: workQueue,
            clock: clock,
            renderersFactory: renderersFactory,
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory,
            audioSessionController: audioSessionController,
            livePlaybackSpeedControl: livePlaybackSpeedControl
        )
    }
}

private extension SEPlayerFactory {
    /// A session for streaming: no HTTP cache of its own, and the long resource timeout of media.
    static func makeSessionLoader() -> IPlayerSessionLoader {
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = SignalQueue(name: "com.seplayer.loader", qos: .userInitiated).queue
        operationQueue.maxConcurrentOperationCount = 1

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.networkServiceType = .avStreaming
        return PlayerSessionLoader(configuration: configuration, queue: operationQueue)
    }

    static func makeDataSourceFactory(
        loaderQueue: Queue,
        sessionLoader: IPlayerSessionLoader,
        diskCache: DiskCache?,
        fileReadQueue: Queue,
        fileMemoryPool: CMMemoryPool
    ) -> DataSourceFactory {
        DefaultDataSourceFactory(
            syncActor: loaderQueue.playerActor(),
            networkLoader: sessionLoader,
            diskCache: diskCache,
            fileReadQueue: fileReadQueue,
            fileMemoryPool: fileMemoryPool
        )
    }
}
