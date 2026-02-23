//
//  Loader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.05.2025.
//

import Dispatch

public protocol Loadable {
    func load(isolation: isolated any Actor) async throws
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

    @discardableResult
    public func startLoading<T: Loadable>(
        loadable: T,
        callback: any Callback<T>,
        defaultMinRetryCount: Int
    ) -> Int64 {
        assert(currentTask == nil)
        fatalError = nil
        let startTimeMs = DispatchTime.now()
        let loadTask = LoadTask(
            workQueue: workQueue,
            loadQueue: loadQueue,
            loadable: loadable,
            loadCallback: callback,
            defaultMinRetryCount: defaultMinRetryCount,
            startTimeMs: startTimeMs
        )
        loadTask.loadDelegate = self
        loadTask.start(delayMillis: 0)
        return startTimeMs.milliseconds
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
            self.workQueue.sync { completion?() }
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
        let type: RetryAction
        let retryDelayMillis: Int64

        var isRetry: Bool { type == .retry || type == .retryResetErrorCount }

        static var retry: LoadErrorAction {
            LoadErrorAction.createRetryAction(
                resetErrorCount: false,
                retryDelayMillis: .timeUnset
            )
        }

        static var retryResetErrorCount: LoadErrorAction {
            LoadErrorAction.createRetryAction(
                resetErrorCount: true,
                retryDelayMillis: .timeUnset
            )
        }

        static var dontRetry: LoadErrorAction {
            LoadErrorAction(
                type: .dontRetry,
                retryDelayMillis: .timeUnset
            )
        }

        static var dontRetryFatal: LoadErrorAction {
            LoadErrorAction(
                type: .dontRetryFatal,
                retryDelayMillis: .timeUnset
            )
        }

        public init(type: RetryAction, retryDelayMillis: Int64) {
            self.type = type
            self.retryDelayMillis = retryDelayMillis
        }

        public static func createRetryAction(resetErrorCount: Bool, retryDelayMillis: Int64) -> LoadErrorAction {
            LoadErrorAction(
                type: resetErrorCount ? .retryResetErrorCount : .retry,
                retryDelayMillis: retryDelayMillis
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

        func onLoadStarted(loadable: T, onTime: Int64, loadDurationMs: Int64, retryCount: Int)
        func onLoadCompleted(loadable: T, onTime: Int64, loadDurationMs: Int64)
        func onLoadCancelled(loadable: T, onTime: Int64, loadDurationMs: Int64, released: Bool)
        func onLoadError(loadable: T, onTime: Int64, loadDurationMs: Int64, error: Error, errorCount: Int) -> Loader.LoadErrorAction
    }

    enum RetryType {
        case retry
        case retryAndResetErrorCount
        case dontRetry
        case dontRetryFatal
    }

    struct LoaderErrorAction {
        let type: RetryType
        let retryDelayMillis: Int64

        var isRetry: Bool {
            type == .retry || type == .retryAndResetErrorCount
        }
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

private final class LoadTask<T: Loadable>: Handler, AnyLoadTask {
    weak var loadDelegate: LoadDelegate?
    let defaultMinRetryCount: Int

    private let lock: UnfairLock
    private let syncActor: PlayerActor
    private let loadable: T
    private let startTimeMs: DispatchTime
    private weak var loadCallback: (any Loader.Callback<T>)?

    private var currentTask: Task<Void, Never>?
    private var currentError: Error?
    private var errorCount = Int.zero
    private var canceled = false
    private var released = false

    init(
        workQueue: Queue,
        loadQueue: Queue,
        loadable: T,
        loadCallback: any Loader.Callback<T>,
        defaultMinRetryCount: Int,
        startTimeMs: DispatchTime
    ) {
        self.syncActor = loadQueue.playerActor()
        self.loadable = loadable
        self.loadCallback = loadCallback
        self.defaultMinRetryCount = defaultMinRetryCount
        self.startTimeMs = startTimeMs
        lock = UnfairLock()

        super.init(queue: workQueue, looper: Looper.myLooper(for: workQueue))
    }

    func maybeThrowError(minRetryCount: Int) throws {
        if let currentError, errorCount > minRetryCount {
            throw currentError
        }
    }

    func start(delayMillis: Int64) {
        loadDelegate?.didStartTask(self)
        if delayMillis > 0 {
            sendEmptyMessageDelayed(LoadMessageKind.start, delayMs: Int(delayMillis))
        } else {
            execute()
        }
    }

    func cancel(released: Bool) {
        lock.withLock { self.released = released }
        currentError = nil
        if hasMessage(LoadMessageKind.start) {
            canceled = true
            removeMessages(LoadMessageKind.start)
            if !released {
                sendEmptyMessage(LoadMessageKind.finish)
            }
        } else {
            lock.withLock { canceled = true }
            currentTask?.cancel()
        }

        if released {
            loadDelegate?.loadFinished()
            let nowMs = DispatchTime.now()
            loadCallback?.onLoadCancelled(
                loadable: loadable,
                onTime: nowMs.milliseconds,
                loadDurationMs: startTimeMs.advanced(by: .nanoseconds(Int(nowMs.uptimeNanoseconds))).milliseconds,
                released: true
            )
        }
    }

    func run(isolation: isolated PlayerActor) async {
        do {
            if lock.withLock({ canceled == false }) {
                try await loadable.load(isolation: isolation)
            }
        } catch {
            if !Task.isCancelled {
                if lock.withLock({ released == false }) {
                    obtainMessage(what: LoadMessageKind.ioError(error)).sendToTarget()
                }

                return
            }
        }

        if lock.withLock({ self.released == false }) {
            sendEmptyMessage(LoadMessageKind.finish)
        }
    }

    override func handleMessage(_ msg: Message) {
        guard lock.withLock({ !released }), let what = msg.what as? LoadMessageKind else { return }

        if what == .start {
            execute(); return
        }

        loadDelegate?.loadFinished()
        let nowMs = DispatchTime.now()
        let durationMs = startTimeMs.advanced(by: .nanoseconds(Int(nowMs.uptimeNanoseconds))).milliseconds
        if lock.withLock({ canceled }) {
            loadCallback?.onLoadCancelled(
                loadable: loadable,
                onTime: nowMs.milliseconds,
                loadDurationMs: durationMs,
                released: false
            )
            return
        }

        if what == .finish {
            loadCallback?.onLoadCompleted(
                loadable: loadable,
                onTime: nowMs.milliseconds,
                loadDurationMs: durationMs
            )
        } else if case let .ioError(error) = what {
            currentError = error
            errorCount += 1
            let action = loadCallback?.onLoadError(
                loadable: loadable,
                onTime: nowMs.milliseconds,
                loadDurationMs: durationMs,
                error: error,
                errorCount: errorCount
            )

            if action?.type == .dontRetryFatal {
                loadDelegate?.loadFatalError(error: error)
            } else if action?.type != .dontRetry {
                if action?.type == .retryResetErrorCount {
                    errorCount = 1
                }

                let retryDelayMs = if let retryDelayMillis = action?.retryDelayMillis,
                                      retryDelayMillis != .timeUnset {
                    retryDelayMillis
                } else {
                    Int64(min((errorCount - 1) * 1000, 5000))
                }

                start(delayMillis: retryDelayMs)
            }
        }
    }

    private func execute() {
        let nowMs = DispatchTime.now()
        let durationMs = startTimeMs.advanced(by: .nanoseconds(Int(nowMs.uptimeNanoseconds))).milliseconds
        loadCallback?.onLoadStarted(
            loadable: loadable,
            onTime: nowMs.milliseconds,
            loadDurationMs: durationMs,
            retryCount: errorCount
        )
        currentError = nil

        let currentTask = Task<Void, Never> {
            await run(isolation: syncActor)
        }
        self.currentTask = currentTask

        Task { await currentTask.value }
    }
}

private extension LoadTask {
    enum LoadMessageKind: MessageKind, Equatable {
        case start
        case finish
        case ioError(Error)

        func isEqual(to other: any MessageKind) -> Bool {
            guard let other = other as? LoadMessageKind else {
                return false
            }

            return self == other
        }

        static func == (lhs: LoadMessageKind, rhs: LoadMessageKind) -> Bool {
            switch (lhs, rhs) {
            case (.start, .start),
                 (.finish, .finish),
                 (.ioError, .ioError):
                return true
            default:
                return false
            }
        }
    }
}
