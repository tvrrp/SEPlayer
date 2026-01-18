//
//  TestSEPlayerFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import AVFoundation
import Testing
@testable import SEPlayer

final class TestSEPlayerFactory {
    private(set) var trackSelector: DefaultTrackSelector
    private(set) var loadControl: LoadControl
    private(set) var bandwidthMeter: BandwidthMeter

    private(set) var clock: SEClock
    private(set) var renderers: [SERenderer]?
    private(set) var renderersFactory: RenderersFactory?
    private(set) var mediaSourceFactory: MediaSourceFactory?
    private(set) var useLazyPreparation = false
    private(set) var queue: Queue?
    private(set) var seekBackIncrementMs: Int64
    private(set) var seekForwardIncrementMs: Int64
    private(set) var maxSeekToPreviousPositionMs: Int64
    private(set) var preloadConfiguration: PreloadConfiguration?

    init(queue: Queue = playerSyncQueue) {
        clock = FakeClock()
        trackSelector = DefaultTrackSelector()
        loadControl = DefaultLoadControl(queue: queue)
        bandwidthMeter = DefaultBandwidthMeter()
        self.queue = queue
        seekBackIncrementMs = 5000
        seekForwardIncrementMs = 15000
        maxSeekToPreviousPositionMs = 3000
    }

    @discardableResult
    func setUseLazyPreparation(_ useLazyPreparation: Bool) -> Self {
        self.useLazyPreparation = useLazyPreparation
        return self
    }

    @discardableResult
    func setTrackSelector(_ trackSelector: DefaultTrackSelector) -> Self {
        self.trackSelector = trackSelector
        return self
    }

    @discardableResult
    func setLoadControl(_ loadControl: LoadControl) -> Self {
        self.loadControl = loadControl
        return self
    }

    @discardableResult
    func setBandwidthMeter(_ bandwidthMeter: BandwidthMeter) -> Self {
        self.bandwidthMeter = bandwidthMeter
        return self
    }

    @discardableResult
    func setRenderers(_ renderers: [SERenderer]) -> Self {
        #expect(renderersFactory == nil)
        self.renderers = renderers
        return self
    }

    @discardableResult
    func setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration) -> Self {
        self.preloadConfiguration = preloadConfiguration
        return self
    }

    @discardableResult
    func setRenderersFactory(_ renderersFactory: RenderersFactory) -> Self {
        #expect(renderers == nil)
        self.renderersFactory = renderersFactory
        return self
    }

    @discardableResult
    func setClock(_ clock: SEClock) -> Self {
        self.clock = clock
        return self
    }

    @discardableResult
    func setQueue(_ queue: Queue) -> Self {
        self.queue = queue
        return self
    }

    @discardableResult
    func setMediaSourceFactory(_ mediaSourceFactory: MediaSourceFactory) -> Self {
        self.mediaSourceFactory = mediaSourceFactory
        return self
    }

    @discardableResult
    func setSeekBackIncrementMs(_ value: Int64) -> Self {
        self.seekBackIncrementMs = value
        return self
    }

    @discardableResult
    func setSeekForwardIncrementMs(_ value: Int64) -> Self {
        self.seekForwardIncrementMs = value
        return self
    }

    @discardableResult
    func setMaxSeekToPreviousPositionMs(_ value: Int64) -> Self {
        self.maxSeekToPreviousPositionMs = value
        return self
    }

    func build() throws -> SEPlayer {
        let queue = try #require(queue, "No work queue is specified")
        let loaderQueue = SignalQueue(name: "test.seplayer.loader")
        #expect(loadControl.queue === queue, "Different queues on load control and builder")

        if renderersFactory == nil {
            renderersFactory = MockRenderersFactory(renderers: renderers ?? [
                FakeRenderer(trackType: .video, clock: clock),
                FakeRenderer(trackType: .audio, clock: clock),
            ])
        }

        let loaderSyncActor = PlayerActor(executor: .init(queue: loaderQueue))
        return try SEPlayerImpl(
            identifier: UUID(),
            workQueue: queue,
            applicationQueue: queue,
            clock: clock,
            renderersFactory: #require(renderersFactory),
            trackSelector: trackSelector,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            mediaSourceFactory: mediaSourceFactory ?? DefaultMediaSourceFactory(
                workQueue: queue,
                loaderSyncActor: loaderSyncActor,
                dataSourceFactory: DefaultDataSourceFactory(
                    syncActor: loaderSyncActor,
                    networkLoader: MockPlayerSessionLoader()
                ),
                extractorsFactory: DefaultExtractorFactory(queue: queue)
            ),
            audioSessionManager: AudioSessionManager.shared,
            useLazyPreparation: useLazyPreparation,
            seekBackIncrementMs: seekBackIncrementMs,
            seekForwardIncrementMs: seekForwardIncrementMs,
            maxSeekToPreviousPositionMs: maxSeekToPreviousPositionMs,
        )
    }
}

private struct MockRenderersFactory: RenderersFactory {
    let renderers: [SERenderer]

    func createRenderers(
        queue: any Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) -> [any SERenderer] {
        renderers
    }
}

private struct MockPlayerSessionLoader: IPlayerSessionLoader {
    func createTask(request: URLRequest, delegate: any PlayerSessionDelegate) -> URLSessionDataTask {
        URLSession.shared.dataTask(with: request)
    }

    func createStream(request: URLRequest) -> AsyncThrowingStream<PlayerSessionLoaderEvent, Error> {
        return AsyncThrowingStream<PlayerSessionLoaderEvent, Error> { $0.finish() }
    }
}
