//
//  ConditionVariable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.05.2025.
//

import Foundation

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

final class AsyncConditionVariable {
    @UnfairLocked var isOpen = false
    @UnfairLocked var waitingContinuation: CheckedContinuation<Void, Error>?

    @discardableResult
    func open() -> Bool {
        guard !isOpen else { return false }

        isOpen = true
        waitingContinuation?.resume()
        waitingContinuation = nil

        return true
    }

    @discardableResult
    func close() -> Bool {
        let wasOpen = isOpen
        isOpen = false

        return wasOpen
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            while !isOpen {
                try await withCheckedThrowingContinuation { continuation in
                    waitingContinuation = continuation
                }
            }
        } onCancel: {
            waitingContinuation?.resume(throwing: CancellationError())
            waitingContinuation = nil
        }
    }
}
