//
//  Loader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.05.2025.
//

import Foundation

protocol Loadable {
    func load(isolation: isolated any Actor) async throws
}

final class Loader {
    private let syncActor: PlayerActor
    private var currentTask: Task<Void, Error>?
//    private let operationQueue: OperationQueue
//    @UnfairLocked private var currentTask: AsyncOperation?

    init(syncActor: PlayerActor) {
        self.syncActor = syncActor
//        operationQueue = OperationQueue()
//        operationQueue.underlyingQueue = queue.queue
//        operationQueue.maxConcurrentOperationCount = 1
    }

    func startLoading<T: Loadable>(loadable: T, callback: any Callback<T>, defaultMinRetryCount: Int) {
//        let operation = LoadTask<T>.init(
//            queue: queue,
//            loadable: loadable,
//            callback: callback,
//            defaultMinRetryCount: defaultMinRetryCount
//        ) { [weak self] error in
//            guard let self else { return }
//            self.currentTask = nil
//            handleLoadCompletion(loadable: loadable, callback: callback, error: error)
//        }
//
//        currentTask = operation
//        operationQueue.addOperation(operation)
        let currentTask = Task<Void, Error> {
            try await loadable.load(isolation: syncActor)
        }
        self.currentTask = currentTask

        Task.detached {
            do {
                try await currentTask.value
                callback.onLoadCompleted(loadable: loadable, onTime: .zero, loadDurationMs: .zero)
            } catch is CancellationError {
                callback.onLoadCancelled(loadable: loadable, onTime: .zero, loadDurationMs: .zero, released: false)
            } catch {
                callback.onLoadError(loadable: loadable, onTime: .zero, loadDurationMs: .zero, error: error, errorCount: 1)
            }
        }
    }

    func isLoading() -> Bool {
        currentTask != nil
    }

    func cancelLoading() {
        currentTask?.cancel()
//        operationQueue.cancelAllOperations()
        currentTask = nil
    }

    func release(completion: (() -> Void)? = nil) {
//        operationQueue.cancelAllOperations()
        currentTask?.cancel()
        currentTask = nil
        if let completion {
//            operationQueue.addOperation {
                completion()
//            }
        }
    }

//    private func handleLoadCompletion<T: Loadable>(loadable: T, callback: any Callback<T>, error: Error?) {
//        if let error {
//            if error is CancellationError {
//                callback.onLoadCancelled(loadable: loadable, onTime: .zero, loadDurationMs: .zero, released: false)
//            } else {
//                callback.onLoadError(loadable: loadable, onTime: .zero, loadDurationMs: .zero, error: error, errorCount: 1)
//            }
//        } else {
//            callback.onLoadCompleted(loadable: loadable, onTime: .zero, loadDurationMs: .zero)
//        }
//    }
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
        @discardableResult
        func onLoadError(loadable: T, onTime: Int64, loadDurationMs: Int64, error: Error, errorCount: Int) -> Loader.LoadErrorAction
    }
}
//
//private extension Loader {
//    final class LoadTask<T: Loadable>: AsyncOperation, @unchecked Sendable {
//        private let queue: Queue
//        private let loadable: T
//        private let callback: any Loader.Callback<T>
//        private let defaultMinRetryCount: Int
//        private let completion: (Error?) -> Void
//
//        init(
//            queue: Queue,
//            loadable: T,
//            callback: any Loader.Callback<T>,
//            defaultMinRetryCount: Int,
//            completion: @escaping (Error?) -> Void
//        ) {
//            self.queue = queue
//            self.loadable = loadable
//            self.callback = callback
//            self.defaultMinRetryCount = defaultMinRetryCount
//            self.completion = completion
//
//            super.init(completion: {})
//        }
//
//        override func work(_ finish: @escaping () -> Void) {
//            do {
//                try loadable.load()
//                completion(isCancelled ? CancellationError() : nil)
//            } catch {
//                completion(error)
//            }
//
//            finish()
//        }
//
//        override func cancel() {
//            loadable.cancelLoad()
//            super.cancel()
//        }
//    }
//}
