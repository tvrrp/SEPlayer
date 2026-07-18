//
//  RWLock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.07.2026.
//

import pthread

public class RWLock {
    private var rwLock = pthread_rwlock_t()

    public init() {
        guard pthread_rwlock_init(&rwLock, nil) == 0 else {
            preconditionFailure("Unable to initialize RWLock")
        }
    }

    deinit {
        pthread_rwlock_destroy(&rwLock)
    }

    public func writeLock() {
        pthread_rwlock_wrlock(&rwLock)
    }

    public func tryWriteLock() {
        pthread_rwlock_trywrlock(&rwLock)
    }

    public func readLock() {
        pthread_rwlock_rdlock(&rwLock)
    }

    public func tryReadLock() {
        pthread_rwlock_tryrdlock(&rwLock)
    }

    public func unlock() {
        pthread_rwlock_unlock(&rwLock)
    }

    public func readProtected<T>(_ aBlock: () throws -> T) rethrows -> T {
        readLock()
        defer { unlock() }
        return try aBlock()
    }

    public func writeProtected<T>(_ aBlock: () throws -> T) rethrows -> T {
        writeLock()
        defer { unlock() }
        return try aBlock()
    }
}
