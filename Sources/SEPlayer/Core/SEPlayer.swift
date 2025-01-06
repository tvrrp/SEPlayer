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

    init(
        identifier: UUID = UUID(),
        returnQueue: Queue = Queues.mainQueue,
        sessionLoader: IPlayerSessionLoader
    ) {
        queue = SignalQueue(name: "com.SEPlayer.work_\(identifier)", qos: .userInitiated)
        self.identifier = identifier
        self.returnQueue = returnQueue
        _dependencies = SEPlayerStateDependencies(
            queue: queue,
            returnQueue: returnQueue,
            sessionLoader: sessionLoader,
            playerId: identifier,
            allocator: DefaultAllocator(queue: queue, trimOnReset: true, individualAllocationSize: Int(getpagesize() * 10))
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

        _state.prepare()
        _state.loading()
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
        let trackGroups = mediaPeriod.trackGroups
        let sampleStreams = mediaPeriod.selectTrack(
            selections: [Void(), Void()], on: .zero
        )
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
