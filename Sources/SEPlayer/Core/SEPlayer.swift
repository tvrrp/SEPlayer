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

    public var state: State { _internalStateQueue.sync { _state.state } }
    private let _internalStateQueue: Queue = Queues.internalStateQueue

    public var playbackRate: Float {
        get { queue.sync { playbackParams.playbackRate } }
        set { queue.async { self.updatePlaybackRate(new: newValue) } }
    }

    private let returnQueue: Queue
    private let queue: Queue

    private lazy var _state: SEPlayerState = SEPlayerBaseState(dependencies: _dependencies, statable: self)
    private let _dependencies: SEPlayerStateDependencies
    private let timer: DispatchSourceTimer

    private var playbackParams = PlaybackParameters.default
    private var rendererPosition: Int64 = 1_000_000_000_000
    private var rendererPositionElapsedRealtime: Int64 = .zero

    private var output: SEPlayerBufferView?

    public var isPlaying: Bool = false

    var clockLastTime = Int64.zero
    var isReady: Bool = false

    var started = false

    init(dependencies: SEPlayerStateDependencies, renderersFactory: RenderersFactory) {
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
        let dataSource = RangeRequestHTTPDataSource(
            queue: Queues.loaderQueue,
            networkLoader: _dependencies.sessionLoader
        )
        let progressiveMediaExtractor = BundledMediaExtractor(
            queue: queue,
            extractorQueue: SignalQueue(name: "com.SEPlayer.extractor_\(identifier)", qos: .userInteractive)
        )

        let mediaSource = ProgressiveMediaSource(
            queue: queue,
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
            loadCondition: self,
            trackSelector: DefaultTrackSelector()
        )
        _dependencies.mediaPeriodHolder = mediaPeriodHolder
        mediaPeriodHolder.prepare(callback: self, on: .zero)
    }
}

extension SEPlayer: SEPlayerStatable {
    func perform(_ state: SEPlayerState) {
        assert(queue.isCurrent())

        _internalStateQueue.sync {
            _state = state
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate.invokeDelegates { $0.player(self, didChangeState: state.state) }
        }

        state.didLoad()
    }
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

        mediaPeriodHolder.handlePrepared(playbackSpeed: 1.0, timeline: SinglePeriodTimeline(), playWhenReady: true)
        do {
//            _dependencies.renderers = try mediaPeriodHolder.sampleStreams.compactMap { stream in
//                let format = stream.format
//                switch stream.format.mediaType {
//                case .video:
//                    return try VTRenderer(
//                        formatDescription: format,
//                        clock: _dependencies.clock,
//                        queue: queue,
//                        displayLink: _dependencies.displayLink,
//                        sampleStream: stream
//                    )
//                case .audio:
//                    return try ATRenderer(
//                        format: format,
//                        clock: _dependencies.clock,
//                        queue: queue,
//                        sampleStream: stream
//                    )
//                default:
//                    return nil
//                }
//            }
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
    }

    func continueLoadingRequested(with source: any MediaPeriod) {
        assert(queue.isCurrent())
    }
}

extension SEPlayer: MediaSourceEventListener {
    func loadStarted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
        assert(queue.isCurrent())
    }

    func loadCompleted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
        assert(queue.isCurrent())
    }

    func loadCancelled(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
        assert(queue.isCurrent())
    }

    func loadError(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void, error: any Error, wasCancelled: Bool) {
        assert(queue.isCurrent())
    }

    func formatChanged(windowIndex: Int, mediaPeriodId: MediaPeriodId?, mediaLoadData: Void) {
        assert(queue.isCurrent())
    }
}

extension SEPlayer: LoadConditionCheckable {
    func checkLoadingCondition() -> Bool {
        assert(queue.isCurrent())
        return true
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
