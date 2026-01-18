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
    @UnfairLocked private var currentTask: Task<Void, Error>?
    private var releaseCompletion: (() -> Void)?

    init(syncActor: PlayerActor) {
        self.syncActor = syncActor
    }

    func startLoading<T: Loadable>(loadable: T, callback: any Callback<T>, defaultMinRetryCount: Int) {
        let currentTask = Task<Void, Error> {
            try await loadable.load(isolation: syncActor)
        }
        self.currentTask = currentTask

        Task {
            await syncActor.run { _ in
                do {
                    try await currentTask.value
                    callback.onLoadCompleted(loadable: loadable, onTime: .zero, loadDurationMs: .zero)
                } catch is CancellationError {
                    callback.onLoadCancelled(loadable: loadable, onTime: .zero, loadDurationMs: .zero, released: false)
                } catch {
                    callback.onLoadError(loadable: loadable, onTime: .zero, loadDurationMs: .zero, error: error, errorCount: 1)
                }

                self.currentTask = nil
                releaseCompletion?()
                releaseCompletion = nil
            }
        }
    }

    func isLoading() -> Bool {
        currentTask != nil
    }

    func cancelLoading() {
        currentTask?.cancel()
    }

    func release(completion: (() -> Void)? = nil) {
        currentTask?.cancel()
        releaseCompletion = completion
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
        @discardableResult
        func onLoadError(loadable: T, onTime: Int64, loadDurationMs: Int64, error: Error, errorCount: Int) -> Loader.LoadErrorAction
    }
}
