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
        condition.broadcast()
        condition.withLock { _didRelease = true }
    }

    func block() {
        condition.lock()
        while !_isOpen, !_didRelease {
            condition.wait()
        }
        condition.unlock()
    }
}
