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

    private let returnQueue: Queue
    private let queue: Queue

    private lazy var _state: SEPlayerState = SEPlayerBaseState(dependencies: _dependencies, statable: self)
    private let _dependencies: SEPlayerStateDependencies

    public var videoRenderer: CALayer {
        queue.sync { _dependencies.videoRenderer }
    }

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
    }

    public func set(content: URL) {
        queue.async { [weak self] in
            self?._set(content: content)
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
        guard let mediaPeriodHolder = _dependencies.mediaPeriodHolder else {
            return
        }
        mediaPeriodHolder.handlePrepared(
            playbackSpeed: 1.0, timeline: SinglePeriodTimeline(), playWhenReady: true, delegate: self
        )
        do {
            _dependencies.decoders = try mediaPeriodHolder.sampleStreams.compactMap { stream in
                let decompressedSamplesQueue = try TypedCMBufferQueue<CMSampleBuffer>(capacity: .max)
                let format = stream.format
                switch stream.format.mediaType {
                case .video:
                    return try SEPlayerStateDependencies.SampleStreamData(
                        decoder: VTDecoder(
                            formatDescription: format,
                            sampleStream: stream,
                            decoderQueue: Queues.decoderQueue,
                            returnQueue: queue,
                            decompressedSamplesQueue: decompressedSamplesQueue
                        ),
                        format: format,
                        renderer: _dependencies.videoRenderer,
                        sampleReleaser: VideoFrameReleaser(
                            queue: Queues.playerOutputsQueue,
                            decompressedSamplesQueue: decompressedSamplesQueue,
                            videoRenderer: _dependencies.videoRenderer,
                            timebase: _dependencies.renderSynchronizer.timebase
                        )
                    )
                case .audio:
                    return try SEPlayerStateDependencies.SampleStreamData(
                        decoder: ACDecoder(
                            formatDescription: format,
                            sampleStream: stream,
                            decoderQueue: Queues.decoderQueue,
                            returnQueue: queue,
                            decompressedSamplesQueue: decompressedSamplesQueue
                        ),
                        format: stream.format,
                        renderer: _dependencies.audioRenderer,
                        sampleReleaser: AudioFrameReleaser(
                            queue: Queues.playerOutputsQueue,
                            decompressedSamplesQueue: decompressedSamplesQueue,
                            audioRenderer: _dependencies.audioRenderer,
                            timebase: _dependencies.renderSynchronizer.timebase
                        )
                    )
                default:
                    return nil
                }
            }
        } catch {
            fatalError()
        }

        _dependencies.taskQueue.start()
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

extension SEPlayer: SampleQueueDelegate {
    func sampleQueue(_ sampleQueue: SampleQueue, didProduceSample onTime: CMSampleTimingInfo) {
        assert(queue.isCurrent())
        guard let index = _dependencies.decoders.firstIndex(where: { $0.format == sampleQueue.format }) else {
            return
        }

        var readyCallback: () -> Void = { [weak self] in
            self?._dependencies.decoders[index].isReady = true
            self?.testIfAllReady()
            
        }

        let wrapper = _dependencies.decoders[index]
        let decoderTask = DecoderReadSampleTask(
            decoder: wrapper.decoder,
            enqueueDecodedSample: true,
            sampleReleaser: wrapper.sampleReleaser,
            readyCallback: wrapper.isReady ? nil : readyCallback
        )

        _dependencies.taskQueue.addTask(decoderTask)
        _dependencies.taskQueue.doNextTask()
    }

    func testIfAllReady() {
        assert(queue.isCurrent())
        if _dependencies.decoders.allSatisfy(\.isReady) {
            _state.play()
        }
    }
}

extension SEPlayer: MediaSourceList.Delegate {
    func playlistUpdateRequested() {
        
    }
}

private extension SEPlayer {
    func createMediaPeriodHolder(mediaPeriodInfo: MediaPeriodInfo, renderPositionOffset: CMTime) {
        
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
