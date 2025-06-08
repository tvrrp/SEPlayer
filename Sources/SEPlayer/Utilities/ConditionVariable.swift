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
        let wasOpen = _isOpen
        _isOpen = false
        condition.broadcast()
        condition.unlock()

        return wasOpen
    }

    func cancel() {
        condition.lock()
        _didRelease = true
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
            while !_isOpen, !_didRelease {
                condition.wait(until: Date(timeIntervalSinceNow: end - now))
                now = Date().timeIntervalSince1970
            }
        }

        let isOpen = _isOpen
        condition.unlock()

        return isOpen
    }
}
