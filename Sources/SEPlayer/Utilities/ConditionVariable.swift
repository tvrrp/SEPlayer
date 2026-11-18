//
//  ConditionVariable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.05.2025.
//

import Foundation
import SEPlayerCommon

final class ConditionVariable {
    var isOpen: Bool { condition.withLock { _isOpen } }

    private var _isOpen: Bool = false
    private var _didRelease: Bool = false
    private let condition = NSCondition()

    @discardableResult
    func open() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !_isOpen else { return false }

        _isOpen = true
        _didRelease = false
        condition.broadcast()

        return true
    }

    @discardableResult
    func close() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let wasOpen = _isOpen
        _isOpen = false

        return wasOpen
    }

    func cancel() {
        condition.lock()
        _didRelease = true
        _isOpen = false
        condition.broadcast()
        condition.unlock()
    }

    func block() {
        condition.lock()
        while !_isOpen, !_didRelease {
            condition.wait()
        }
        condition.unlock()
    }

    @discardableResult
    func block(timeout: TimeInterval) -> Bool {
        if timeout <= .zero {
            return isOpen
        }

        condition.lock()
        var now = Date().timeIntervalSince1970
        let end = now + timeout

        if end < now {
            condition.wait()
        } else {
            while !_isOpen, !_didRelease, now < end {
                condition.wait(until: Date(timeIntervalSinceNow: end - now))
                now = Date().timeIntervalSince1970
            }
        }

        let isOpen = _isOpen
        condition.unlock()

        return isOpen
    }
}

/// Lets the loader pause while the buffer is full.
///
/// The open flag and the waiters share one lock, so an `open()` or a cancellation that races with
/// `wait()` is never missed.
final class AsyncConditionVariable: @unchecked Sendable {
    var isOpen: Bool { lock.withLock { _isOpen } }

    private let lock = UnfairLock()
    private var _isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    @discardableResult
    func open() -> Bool {
        let waiters: [CheckedContinuation<Void, Error>]? = lock.withLock {
            guard !_isOpen else { return nil }
            _isOpen = true
            defer { self.waiters.removeAll() }
            return Array(self.waiters.values)
        }

        waiters?.forEach { $0.resume() }
        return waiters != nil
    }

    @discardableResult
    func close() -> Bool {
        lock.withLock {
            let wasOpen = _isOpen
            _isOpen = false
            return wasOpen
        }
    }

    /// Returns once the condition is open. Throws `CancellationError` if the task is cancelled.
    func wait() async throws {
        let id = UUID()

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    addWaiter(id, continuation: continuation)
                }
            },
            onCancel: {
                cancelWaiter(id)
            }
        )
    }

    private func addWaiter(_ id: UUID, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()

        // Checked under the lock: a cancellation handler that ran before this found no waiter to
        // resume, but the task is already marked cancelled.
        if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else if _isOpen {
            lock.unlock()
            continuation.resume()
        } else {
            waiters[id] = continuation
            lock.unlock()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}
