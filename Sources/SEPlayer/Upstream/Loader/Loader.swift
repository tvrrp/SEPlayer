//
//  Loader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.05.2025.
//

import Dispatch
import Foundation
import SEPlayerCommon

public protocol Loadable {
    func load(_ isolation: isolated any Actor) async throws
}

public final class Loader {
    private let workQueue: Queue
    private let loadQueue: Queue
    private var currentTask: AnyLoadTask?
    private var fatalError: Error?

    public init(workQueue: Queue, loadQueue: Queue) {
        self.workQueue = workQueue
        self.loadQueue = loadQueue
    }

    public func hasFatalError() -> Bool {
        fatalError != nil
    }

    public func clearFatalError() {
        fatalError = nil
    }

    /// Starts loading.
    ///
    /// - Returns: When the load started.
    @discardableResult
    public func startLoading<T: Loadable>(
        loadable: T,
        callback: any Callback<T>,
        defaultMinRetryCount: Int
    ) -> DispatchTime {
        assert(currentTask == nil)
        fatalError = nil
        let startTime = DispatchTime.now()
        let loadTask = LoadTask(
            workQueue: workQueue,
            loadQueue: loadQueue,
            loadable: loadable,
            loadCallback: callback,
            defaultMinRetryCount: defaultMinRetryCount,
            startTime: startTime
        )
        loadTask.loadDelegate = self
        loadTask.start(delay: nil)
        return startTime
    }

    public func isLoading() -> Bool {
        currentTask != nil
    }

    public func cancelLoading() {
        currentTask?.cancel(released: false)
    }

    public func release(completion: (() -> Void)? = nil) {
        currentTask?.cancel(released: true)
        loadQueue.async {
            self.workQueue.async { completion?() }
        }
    }

    public func maybeThrowError(minRetryCount: Int? = nil) throws {
        if let fatalError {
            throw fatalError
        } else if let currentTask {
            try currentTask.maybeThrowError(
                minRetryCount: minRetryCount ?? currentTask.defaultMinRetryCount
            )
        }
    }
}

public extension Loader {
    struct LoadErrorAction {
        public let type: RetryAction
        /// The delay before the retry, or `nil` for the default delay: a second more for each error in a row, up to
        /// five seconds.
        public let retryDelay: DispatchTimeInterval?

        public var isRetry: Bool { type == .retry || type == .retryResetErrorCount }

        public static var retry: LoadErrorAction {
            LoadErrorAction.createRetryAction(resetErrorCount: false, retryDelay: nil)
        }

        public static var retryResetErrorCount: LoadErrorAction {
            LoadErrorAction.createRetryAction(resetErrorCount: true, retryDelay: nil)
        }

        /// The load stops, but its error doesn't stop playback: the callback falls back to something else.
        public static var dontRetry: LoadErrorAction {
            LoadErrorAction(type: .dontRetry, retryDelay: nil)
        }

        /// The load stops, and ``Loader/maybeThrowError(minRetryCount:)`` throws its error from now on.
        public static var dontRetryFatal: LoadErrorAction {
            LoadErrorAction(type: .dontRetryFatal, retryDelay: nil)
        }

        public init(type: RetryAction, retryDelay: DispatchTimeInterval?) {
            self.type = type
            self.retryDelay = retryDelay
        }

        public static func createRetryAction(resetErrorCount: Bool, retryDelay: DispatchTimeInterval?) -> LoadErrorAction {
            LoadErrorAction(
                type: resetErrorCount ? .retryResetErrorCount : .retry,
                retryDelay: retryDelay
            )
        }
    }

    enum RetryAction {
        case retry
        case retryResetErrorCount
        case dontRetry
        case dontRetryFatal
    }
}

public extension Loader {
    protocol Callback<T>: AnyObject where T: Loadable {
        associatedtype T

        /// Called when the load, or a retry of it, starts.
        func onLoadStarted(loadable: T, onTime: DispatchTime, loadDuration: DispatchTimeInterval, retryCount: Int)
        /// Called when the load completed.
        func onLoadCompleted(loadable: T, onTime: DispatchTime, loadDuration: DispatchTimeInterval)
        /// Called when the load was cancelled, or the loader released.
        func onLoadCancelled(loadable: T, onTime: DispatchTime, loadDuration: DispatchTimeInterval, released: Bool)
        /// Called when the load failed.
        ///
        /// - Parameter loadDuration: How long since the load first started, retries included.
        /// - Returns: Whether and when the load retries.
        func onLoadError(
            loadable: T,
            onTime: DispatchTime,
            loadDuration: DispatchTimeInterval,
            error: Error,
            errorCount: Int
        ) -> Loader.LoadErrorAction
    }

}

extension Loader: LoadDelegate {
    fileprivate func didStartTask(_ task: any AnyLoadTask) {
        currentTask = task
    }

    func loadFinished() {
        currentTask = nil
    }

    func loadFatalError(error: any Error) {
        fatalError = error
    }
}

private protocol AnyLoadTask {
    var defaultMinRetryCount: Int { get }
    func cancel(released: Bool)
    func maybeThrowError(minRetryCount: Int) throws
}

private protocol LoadDelegate: AnyObject {
    func didStartTask(_ task: AnyLoadTask)
    func loadFinished()
    func loadFatalError(error: Error)
}

/// One load, and its retries. Started, cancelled and told how it went on the work queue; it loads on the load queue.
private final class LoadTask<T: Loadable>: AnyLoadTask {
    weak var loadDelegate: LoadDelegate?
    let defaultMinRetryCount: Int

    private let lock: UnfairLock
    private let workQueue: Queue
    private let syncActor: PlayerActor
    private let loadable: T
    private let startTime: DispatchTime
    private weak var loadCallback: (any Loader.Callback<T>)?

    private var currentTask: Task<Void, Never>?
    private var currentError: Error?
    private var errorCount = Int.zero
    private var canceled = false
    private var released = false
    /// The start of a retry, waiting for its delay. Used on the work queue.
    private var pendingStart: DispatchWorkItem?

    init(
        workQueue: Queue,
        loadQueue: Queue,
        loadable: T,
        loadCallback: any Loader.Callback<T>,
        defaultMinRetryCount: Int,
        startTime: DispatchTime
    ) {
        self.workQueue = workQueue
        self.syncActor = loadQueue.playerActor()
        self.loadable = loadable
        self.loadCallback = loadCallback
        self.defaultMinRetryCount = defaultMinRetryCount
        self.startTime = startTime
        lock = UnfairLock()
    }

    func maybeThrowError(minRetryCount: Int) throws {
        if let currentError, errorCount > minRetryCount {
            throw currentError
        }
    }

    func start(delay: DispatchTimeInterval?) {
        loadDelegate?.didStartTask(self)
        if let delay, delay.totalMilliseconds > 0 {
            let start = DispatchWorkItem { [self] in
                pendingStart = nil
                guard lock.withLock({ !released }) else { return }
                execute()
            }
            pendingStart = start
            workQueue.queue.asyncAfter(deadline: .now() + delay, execute: start)
        } else {
            execute()
        }
    }

    func cancel(released: Bool) {
        SELogger.debug(.loader, "Canceling \(T.self)\(released ? ", releasing the loader" : "")")
        lock.withLock { self.released = released }
        currentError = nil
        if let pendingStart {
            canceled = true
            pendingStart.cancel()
            self.pendingStart = nil
            if !released {
                post(.finish)
            }
        } else {
            lock.withLock { canceled = true }
            currentTask?.cancel()
        }

        if released {
            loadDelegate?.loadFinished()
            let now = DispatchTime.now()
            loadCallback?.onLoadCancelled(
                loadable: loadable,
                onTime: now,
                loadDuration: startTime.distance(to: now),
                released: true
            )
        }
    }

    func run(_ isolation: isolated PlayerActor) async {
        do {
            if lock.withLock({ canceled == false }) {
                try await loadable.load(isolation)
            }
        } catch {
            if !Task.isCancelled {
                if lock.withLock({ released == false }) {
                    post(.ioError(error))
                }

                return
            }
        }

        if lock.withLock({ self.released == false }) {
            post(.finish)
        }
    }

    /// Handles `event` on the work queue, after the work posted there before it.
    private func post(_ event: LoadEvent) {
        workQueue.justDispatch { [self] in handle(event) }
    }

    private func handle(_ event: LoadEvent) {
        guard lock.withLock({ !released }) else { return }

        loadDelegate?.loadFinished()
        let now = DispatchTime.now()
        let duration = startTime.distance(to: now)
        if lock.withLock({ canceled }) {
            loadCallback?.onLoadCancelled(
                loadable: loadable,
                onTime: now,
                loadDuration: duration,
                released: false
            )
            return
        }

        switch event {
        case .finish:
            SELogger.verbose(.loader, "\(T.self) finished in \(duration.totalMilliseconds)ms")
            loadCallback?.onLoadCompleted(
                loadable: loadable,
                onTime: now,
                loadDuration: duration
            )
        case let .ioError(error):
            currentError = error
            errorCount += 1
            // Nobody is left to hear a retry.
            let action = loadCallback?.onLoadError(
                loadable: loadable,
                onTime: now,
                loadDuration: duration,
                error: error,
                errorCount: errorCount
            ) ?? .dontRetry

            switch action.type {
            case .dontRetryFatal:
                SELogger.error(.loader, "\(T.self) failed for good after \(errorCount) errors: \(error)")
                loadDelegate?.loadFatalError(error: error)
            case .dontRetry:
                SELogger.warning(.loader, "\(T.self) failed, not retrying: \(error)")
            case .retry, .retryResetErrorCount:
                if action.type == .retryResetErrorCount {
                    errorCount = 1
                }

                let delay = action.retryDelay ?? .milliseconds(min((errorCount - 1) * 1000, 5000))
                SELogger.info(.loader, "Retrying \(T.self) in \(delay.totalMilliseconds)ms, error \(errorCount): \(error)")
                start(delay: delay)
            }
        }
    }

    private func execute() {
        SELogger.verbose(.loader, "Starting \(T.self)\(errorCount > 0 ? ", retry \(errorCount)" : "")")
        let now = DispatchTime.now()
        loadCallback?.onLoadStarted(
            loadable: loadable,
            onTime: now,
            loadDuration: startTime.distance(to: now),
            retryCount: errorCount
        )
        currentError = nil

        let currentTask = Task<Void, Never> {
            await run(syncActor)
        }
        self.currentTask = currentTask

        Task { await currentTask.value }
    }
}

private extension LoadTask {
    /// How the load went, told on the work queue.
    enum LoadEvent {
        case finish
        case ioError(Error)
    }
}
