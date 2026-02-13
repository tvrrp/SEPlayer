//
//  CountDownLatch.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import Testing

struct TimeoutError: Swift.Error {}

final class CountDownLatch {

    var count: Int
    var timeoutTask: Task<Void, Error>?

    init(count: Int) {
        self.count = count
    }

    func awaitResult(timeoutMs: UInt64, isolation: isolated (any Actor)? = #isolation) async throws {
        guard count > 0 else { return } 
        let timeoutTask = Task {
            try Task.checkCancellation()
            if #available(iOS 16, *) {
                try await Task.sleep(for: .milliseconds(timeoutMs))
            } else {
                try await Task.sleep(for: .milliseconds(Int(timeoutMs)), leeway: .zero)
            }
            try Task.checkCancellation()
            return
        }

        self.timeoutTask = timeoutTask

        do {
            try await timeoutTask.value
        } catch is CancellationError {
            return
        }

        throw TimeoutError()
    }

    func getCount(isolation: isolated (any Actor)? = #isolation) -> Int {
        return count
    }

    func countDown(isolation: isolated (any Actor)? = #isolation) {
        count -= 1
        if count <= 0 {
            timeoutTask?.cancel()
        }
    }
}

final class TimeoutChecker {
    private var task: Task<Void, Never>?

    func start(timeoutMs: UInt64, onTimeout: @escaping (Error) -> Void) {
        task = Task {
            do {
                try Task.checkCancellation()
                if #available(iOS 16, *) {
                    try await Task.sleep(for: .milliseconds(timeoutMs))
                } else {
                    try await Task.sleep(for: .milliseconds(Int(timeoutMs)), leeway: .zero)
                }
                try Task.checkCancellation()
                onTimeout(TimeoutError())
            } catch {
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
