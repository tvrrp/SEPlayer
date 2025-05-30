//
//  Loader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.05.2025.
//

import Foundation

protocol Loadable {
    func cancelLoad()
    func load(queue: Queue, completion: @escaping (Error?) -> Void)
}

final class Loader {
    private let queue: Queue
    private let operationQueue: OperationQueue
    private var currentTask: AsyncOperation?

    init(queue: Queue) {
        self.queue = queue
        operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue.queue
        operationQueue.maxConcurrentOperationCount = 1
    }

    func startLoading<T: Loadable>(loadable: T, callback: any Callback<T>, defaultMinRetryCount: Int) {
        let operation = LoadTask<T>.init(
            queue: queue,
            loadable: loadable,
            callback: callback,
            defaultMinRetryCount: defaultMinRetryCount
        ) { [weak self] error in
            guard let self else { return }
            withLock { self.currentTask = nil }
            handleLoadCompletion(loadable: loadable, callback: callback, error: error)
        }

        withLock { currentTask = operation }
        operationQueue.addOperation(operation)
    }

    func isLoading() -> Bool {
        withLock { currentTask != nil }
    }

    func cancelLoading() {
        operationQueue.cancelAllOperations()
    }

    func release(completion: (() -> Void)? = nil) {
        operationQueue.cancelAllOperations()
        if let completion {
            operationQueue.addOperation {
                completion()
            }
        }
    }

    private func handleLoadCompletion<T: Loadable>(loadable: T, callback: any Callback<T>, error: Error?) {
        if let error {
            
        } else {
            callback.onLoadCompleted(loadable: loadable, onTime: .zero, loadDurationMs: .zero)
        }
    }

    private var unfairLock = os_unfair_lock_s()

    private func withLock<T>(_ action: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfairLock)
        let value = try action()
        os_unfair_lock_unlock(&unfairLock)
        return value
    }
}

extension Loader {
    struct LoadErrorAction {
        let type: RetryAction
        let retryDelayMillis: Int64

        var isRetry: Bool { type == .retry || type == .retryResetErrorCount }
    }

    enum RetryAction {
        case retry
        case retryResetErrorCount
        case dontRetry
        case dontRetryFatal
    }
}

extension Loader {
    protocol Callback<T>: AnyObject where T: Loadable {
        associatedtype T

        func onLoadStarted(loadable: T, onTime: Int64, loadDurationMs: Int64, retryCount: Int)
        func onLoadCompleted(loadable: T, onTime: Int64, loadDurationMs: Int64)
        func onLoadCancelled(loadable: T, onTime: Int64, loadDurationMs: Int64, released: Bool)
        func onLoadError(loadable: T, onTime: Int64, loadDurationMs: Int64, error: Error, errorCount: Int) -> Loader.LoadErrorAction
    }
}

private extension Loader {
    final class LoadTask<T: Loadable>: AsyncOperation, @unchecked Sendable {
        private let queue: Queue
        private let loadable: T
        private let callback: any Loader.Callback<T>
        private let defaultMinRetryCount: Int
        private let completion: (Error?) -> Void

        init(
            queue: Queue,
            loadable: T,
            callback: any Loader.Callback<T>,
            defaultMinRetryCount: Int,
            completion: @escaping (Error?) -> Void
        ) {
            self.queue = queue
            self.loadable = loadable
            self.callback = callback
            self.defaultMinRetryCount = defaultMinRetryCount
            self.completion = completion

            super.init(completion: {})
        }

        override func work(_ finish: @escaping () -> Void) {
            loadable.load(queue: queue) { [weak self] error in
                guard let self else { return }
                completion(error)

                finish()
            }
        }

        override func cancel() {
            loadable.cancelLoad()
            super.cancel()
        }
    }
}
