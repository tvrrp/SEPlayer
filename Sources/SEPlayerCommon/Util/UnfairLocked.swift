//
//  Atomic.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.09.2025.
//

import Foundation

@propertyWrapper
public final class UnfairLocked<Value> {
    private var value: Value
    private let lock = UnfairLock()

    public var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    public init(wrappedValue value: Value) {
        self.value = value
    }
}

public final class UnfairLock: NSLocking, @unchecked Sendable {
    @usableFromInline
    let unfairLock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    public init() {}

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inlinable
    public func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    @inlinable
    public func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}

public extension NSLocking {
    func usingLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        lock(); defer { unlock() }
        let result = try body()
        return result
    }
}
