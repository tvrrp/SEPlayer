//
//  CountDownLatch.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

final class CountDownLatch {
    struct TimeoutError: Swift.Error {}

    var count: Int
    var timeoutTask: Task<Void, Error>?

    init(count: Int) {
        self.count = count
    }

    func awaitResult(timeoutMs: UInt64, isolation: isolated (any Actor)? = #isolation) async throws {
        let timeoutTask = Task {
            try Task.checkCancellation()
            try await Task.sleep(milliseconds: timeoutMs)
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
