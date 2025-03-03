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
        get { queue.sync { _playbackRate } }
        set { queue.async { self.updatePlaybackRate(new: newValue) } }
    }

    private let returnQueue: Queue
    private let queue: Queue

    private lazy var _state: SEPlayerState = SEPlayerBaseState(dependencies: _dependencies, statable: self)
    private let _dependencies: SEPlayerStateDependencies
    private let timer: DispatchSourceTimer

    private var _playbackRate: Float = 1.0
    private var rendererPosition: Int64 = 1_000_000_000_000
    private var rendererPositionElapsedRealtime: Int64 = .zero

    private var output: SEPlayerBufferView?

    public var isPlaying: Bool = false

    var clockLastTime = Int64.zero
    var isReady: Bool = false

    var started = false

    init(
        identifier: UUID = UUID(),
        returnQueue: Queue = Queues.mainQueue,
        sessionLoader: IPlayerSessionLoader
    ) {
        queue = SignalQueue(name: "com.SEPlayer.work_\(identifier)", qos: .userInitiated)
        self.identifier = identifier
        self.returnQueue = returnQueue
        let allocator = DefaultAllocator(queue: queue, trimOnReset: true)

        _dependencies = SEPlayerStateDependencies(
            queue: queue,
            returnQueue: returnQueue,
            sessionLoader: sessionLoader,
            playerId: identifier,
            allocator: allocator
        )
        self.timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue.queue)
        setupTimer()
    }

    public func set(content: URL) {
        queue.async { [weak self] in
            self?._set(content: content)
        }
    }

    public func play() {
        queue.async { [self] in
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
                _dependencies.renderers.forEach { $0.pause() }
                _dependencies.standaloneClock.stop()
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
            allocator: _dependencies.allocator,
            mediaSourceList: mediaSourceList,
            info: .init(
                id: .init(periodId: UUID(), windowSequenceNumber: 0), startPosition: .zero, requestedContentPosition: .zero, endPosition: .zero, duration: .zero
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
            _dependencies.renderers = try mediaPeriodHolder.sampleStreams.compactMap { stream in
                let format = stream.format
                switch stream.format.mediaType {
                case .video:
                    return try VTRenderer(
                        formatDescription: format,
                        clock: _dependencies.clock,
                        queue: queue,
                        displayLink: _dependencies.displayLink,
                        sampleStream: stream
                    )
                case .audio:
                    return try ATRenderer(
                        format: format,
                        clock: _dependencies.clock,
                        queue: queue,
                        sampleStream: stream
                    )
                default:
                    return nil
                }
            }
        } catch {
            fatalError()
        }

        if let output {
            for renderer in _dependencies.renderers.compactMap({ $0 as? VTRenderer }) {
                renderer.setBufferOutput(output)
            }
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

        rendererPosition = _dependencies.standaloneClock.getPosition()
        rendererPositionElapsedRealtime = _dependencies.clock.microseconds

        var renderersReady = true
        for renderer in _dependencies.renderers {
            try! renderer.render(position: rendererPosition, elapsedRealtime: rendererPositionElapsedRealtime)
            renderersReady = renderersReady && renderer.isReady()
        }

        if renderersReady && !isReady {
            isPlaying = true
            isReady = true
            updatePlaybackRate(new: 1.0)
//            sleep(2)
            _dependencies.renderers.forEach { $0.start() }
            _dependencies.standaloneClock.start()
        }

        if !renderersReady && isReady {
            isReady = false
            _dependencies.renderers.forEach { $0.pause() }
            _dependencies.standaloneClock.stop()
        }

        timer.schedule(deadline: currentTime + .milliseconds(10))
    }

    private func updatePlaybackRate(new playbackRate: Float) {
        assert(queue.isCurrent())
        let clampedPlaybackRate = min(max(0.1, playbackRate), 2.5)
        self._playbackRate = clampedPlaybackRate
        _dependencies.standaloneClock.setPlaybackRate(new: playbackRate)
        _dependencies.renderers.forEach { try? $0.setPlaybackRate(new: playbackRate) }
    }
}

extension SEPlayer {
    func setBufferOutput(_ output: SEPlayerBufferView) {
        queue.async { [weak self] in
            guard let self else { return }
            self.output = output

            for renderer in _dependencies.renderers.compactMap({ $0 as? VTRenderer }) {
                renderer.setBufferOutput(output)
            }
        }
    }

    func removeBufferOutput(_ output: SEPlayerBufferView) {
        queue.async { [weak self] in
            guard let self else { return }
            self.output = nil
            for renderer in _dependencies.renderers.compactMap({ $0 as? VTRenderer }) {
                renderer.setBufferOutput(output)
            }
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

        // MARK: - Static

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
