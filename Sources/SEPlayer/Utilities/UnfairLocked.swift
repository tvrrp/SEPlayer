//
//  Atomic.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.09.2025.
//

import Foundation

@propertyWrapper
final class UnfairLocked<Value> {
    private var value: Value
    private let lock = UnfairLock()

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    init(wrappedValue value: Value) {
        self.value = value
    }
}

final class UnfairLock: NSLocking {
    private let unfairLock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inlinable
    func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    @inlinable
    func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}
