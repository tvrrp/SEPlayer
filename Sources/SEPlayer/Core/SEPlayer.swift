//
//  SEPlayer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFoundation

public final class SEPlayer {
    @MainActor public let delegate = MulticastDelegate<SEPlayerDelegate>(isThreadSafe: false)

    public let identifier: UUID

    private let _internalStateQueue: Queue = Queues.internalStateQueue

    public var playbackRate: Float {
        get { queue.sync { playbackParams.playbackRate } }
        set { queue.async { self.updatePlaybackRate(new: newValue) } }
    }

    private let returnQueue: Queue
    private let queue: Queue

    private let _dependencies: SEPlayerDependencies
    private let timer: DispatchSourceTimer

    private var playbackParams = PlaybackParameters.default
    private var rendererPosition: Int64 = 1_000_000_000_000
    private var rendererPositionElapsedRealtime: Int64 = .zero

    private var output: SEPlayerBufferView?

    public var isPlaying: Bool = false

    var clockLastTime = Int64.zero
    var isReady: Bool = false

    var started = false

    init(dependencies: SEPlayerDependencies, renderersFactory: RenderersFactory) {
        self.queue = dependencies.queue
        self.identifier = dependencies.playerId
        self.returnQueue = dependencies.returnQueue

        _dependencies = dependencies
        _dependencies.renderers = renderersFactory
            .createRenderers(dependencies: _dependencies)
        self.timer = DispatchSource.makeTimerSource(queue: queue.queue)
        setupTimer()
    }

    public func set(content: URL) {
        queue.async { [weak self] in
            self?._set(content: content)
        }
    }

    public func play() {
        queue.async { [self] in
            guard _dependencies.mediaPeriodHolder?.isPrepared == true else {
                return
            }
            if !isPlaying {
                timer.resume()
                isPlaying = true
            }
        }
    }

    public func pause() {
        queue.async { [self] in
            if isPlaying {
                timer.suspend()
                isReady = false
                isPlaying = false
                stopRenderers()
            }
        }
    }
}

private extension SEPlayer {
    func _set(content: URL) {
        assert(queue.isCurrent())
        let loaderQueue = SignalQueue(name: "com.seplayer.loader_\(identifier)", qos: .userInteractive)
        let dataSource = RangeRequestHTTPDataSource(
            queue: Queues.loaderQueue,
            networkLoader: _dependencies.sessionLoader
        )
        let progressiveMediaExtractor = BundledMediaExtractor(
            queue: loaderQueue,
            extractorQueue: loaderQueue
        )

        let mediaSource = ProgressiveMediaSource(
            queue: queue,
            loaderQueue: loaderQueue,
            mediaItem: .init(url: content),
            dataSource: dataSource,
            progressiveMediaExtractor: progressiveMediaExtractor,
            continueLoadingCheckIntervalBytes: 1024 * 1024
        )
        _dependencies.mediaSource = mediaSource

        let mediaSourceList = MediaSourceList(delegate: self, playerId: identifier)
        mediaSourceList.setMediaSource(holders: [.init(mediaSource: mediaSource)])

        let mediaPeriodHolder = MediaPeriodHolder(
            queue: queue,
            rendererCapabilities: _dependencies.renderers.map { $0.getCapabilities() },
            allocator: _dependencies.allocator,
            mediaSourceList: mediaSourceList,
            info: .init(
                id: .init(periodId: UUID(), windowSequenceNumber: 0), startPosition: .zero, requestedContentPosition: .zero, endPosition: .zero, duration: .zero, isFinal: false
            ),
            trackSelector: DefaultTrackSelector()
        )
        mediaPeriodHolder.renderPositionOffset = rendererPosition
        _dependencies.mediaPeriodHolder = mediaPeriodHolder
        mediaPeriodHolder.prepare(callback: self, on: .zero)
    }

    private func maybeContinueLoading() {
        if shouldContinueLoading(), let loadingPeriod = _dependencies.mediaPeriodHolder {
            loadingPeriod.continueLoading(loadingInfo: .init(
                playbackPosition: loadingPeriod.toPeriodTime(rendererTime: rendererPosition),
                playbackSpeed: _dependencies.standaloneClock.getPlaybackParameters().playbackRate,
                lastRebufferRealtime: .zero
            ))
        }
        updateIsLoading()
    }

    private func shouldContinueLoading() -> Bool {
//        _dependencies.
        return true
    }

    private func isLoadingPossible(mediaPeriodHolder: MediaPeriodHolder?) -> Bool {
        guard let mediaPeriodHolder else { return false }

        return mediaPeriodHolder.getNextLoadPosition() != .timeUnset
    }

    private func updateIsLoading() {}
}

extension SEPlayer: MediaSourceDelegate {
    func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline?) {
        assert(queue.isCurrent())
    }
}

extension SEPlayer: MediaPeriodCallback {
    func didPrepare(mediaPeriod: any MediaPeriod) {
        assert(queue.isCurrent())
        guard let mediaPeriodHolder = _dependencies.mediaPeriodHolder else { return }

        if !mediaPeriodHolder.isPrepared {
            mediaPeriodHolder.handlePrepared(
                playbackSpeed: _dependencies.standaloneClock.getPlaybackParameters().playbackRate,
                timeline: SinglePeriodTimeline(),
                playWhenReady: true
            )
        }

        do {
            for (index, sampleStream) in mediaPeriodHolder.sampleStreams.enumerated() {
                if let sampleStream {
                    try _dependencies.renderers[index].enable(
                        formats: [],
                        stream: sampleStream,
                        position: 0,
                        joining: false,
                        mayRenderStartOfStream: true,
                        startPosition: rendererPosition,
                        offset: rendererPosition,
                        mediaPeriodId: mediaPeriodHolder.info.id
                    )
                } else {
                    continue
                }
            }
        } catch {
            fatalError()
        }

        for renderer in _dependencies.renderers {
            _dependencies.standaloneClock.onRendererEnabled(renderer: renderer)
        }

        _dependencies.standaloneClock.resetPosition(position: rendererPosition)
        self.timer.resume()
        self.doSomeWork()
        maybeContinueLoading()
    }

    func continueLoadingRequested(with source: any MediaPeriod) {
        assert(queue.isCurrent())
        maybeContinueLoading()
    }
}

extension SEPlayer: MediaSourceList.Delegate {
    func playlistUpdateRequested() {
        
    }
}

private extension SEPlayer {
    private func setupTimer() {
        timer.setEventHandler { [weak self] in
            self?.doSomeWork()
        }
    }

    private func doSomeWork() {
        assert(queue.isCurrent())
        let currentTime = DispatchTime.now()

        rendererPosition = _dependencies.standaloneClock.syncAndGetPosition(isReadingAhead: false)
        rendererPositionElapsedRealtime = _dependencies.clock.microseconds

        var renderersReady = true
        for renderer in _dependencies.renderers {
            try! renderer.render(position: rendererPosition, elapsedRealtime: rendererPositionElapsedRealtime)
            renderersReady = renderersReady && renderer.isReady()
        }

        if renderersReady && !isReady {
            isPlaying = true
            isReady = true
//            updatePlaybackRate(new: 2.0)
            _dependencies.standaloneClock.start()
            enableRenderers()
        }

        if !renderersReady && isReady {
            isReady = false
            stopRenderers()
        }

        let time = _dependencies.mediaPeriodHolder?.toPeriodTime(rendererTime: rendererPosition) ?? .zero
        _dependencies.mediaPeriodHolder?.mediaPeriod.discardBuffer(to: time, toKeyframe: true)
        timer.schedule(deadline: currentTime + .milliseconds(10))
    }

    private func enableRenderers() {
        _dependencies.renderers.forEach { try! $0.start() }
    }

    private func stopRenderers() {
        _dependencies.standaloneClock.stop()
        _dependencies.renderers.forEach { $0.stop() }
    }

    private func updatePlaybackRate(new playbackRate: Float) {
        assert(queue.isCurrent())
        let old = playbackParams
        self.playbackParams = PlaybackParameters(playbackRate: playbackRate)
        _dependencies.standaloneClock.setPlaybackParameters(new: playbackParams)
        _dependencies.renderers.forEach {
            try? $0.setPlaybackSpeed(current: old.playbackRate, target: playbackParams.playbackRate)
        }
    }
}

extension SEPlayer {
    func register(_ bufferable: PlayerBufferable) {
        queue.async { [weak self] in
            guard let self else { return }
            _dependencies.bufferableContainer.register(bufferable)
        }
    }

    func remove(_ bufferable: PlayerBufferable) {
        queue.async { [weak self] in
            guard let self else { return }
            _dependencies.bufferableContainer.remove(bufferable)
        }
    }
}

public extension SEPlayer {
    enum State: Equatable {
        case idle
        case playing
        case stalled
        case paused
        case ready
        case seeking(Double, (() -> Void)?)
        case loading
        case ended
        case error(Error?)

        public static func == (lhs: State, rhs: State) -> Bool {
            if case .idle = lhs, case .idle = rhs { return true }
            if case .playing = lhs, case .playing = rhs { return true }
            if case .stalled = lhs, case .stalled = rhs { return true }
            if case .paused = lhs, case .paused = rhs { return true }
            if case .ready = lhs, case .ready = rhs { return true }
            if case .seeking = lhs, case .seeking = rhs { return true }
            if case .loading = lhs, case .loading = rhs { return true }
            if case .ended = lhs, case .ended = rhs { return true }
            if case .error = lhs, case .error = rhs { return true }

            return false
        }
    }
}
