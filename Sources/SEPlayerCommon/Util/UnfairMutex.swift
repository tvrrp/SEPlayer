//
//  UnfairMutex.swift
//  SEPlayer
//

import os

/// A value that is only reachable under an unfair lock.
///
/// The unfair lock donates priority, which reads on renderer and audio threads need.
public final class UnfairMutex<Value>: @unchecked Sendable {
    private var value: Value
    private let unfairLock: UnsafeMutablePointer<os_unfair_lock_s>

    public init(_ value: Value) {
        self.value = value
        self.unfairLock = .allocate(capacity: 1)
        self.unfairLock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inline(__always)
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return try body(&value)
    }
}
