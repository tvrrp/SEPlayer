//
//  RWLock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 17.07.2026.
//

import Darwin
import Foundation

public final class RWLock: @unchecked Sendable {
    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t>

    public init() {
        rwlock = .allocate(capacity: 1)
        let result = pthread_rwlock_init(rwlock, nil)
        precondition(result == 0, "pthread_rwlock_init failed: \(String(cString: strerror(result)))")
    }

    deinit {
        let result = pthread_rwlock_destroy(rwlock)
        precondition(result == 0, "pthread_rwlock_destroy failed: \(String(cString: strerror(result)))")
        rwlock.deallocate()
    }

    // MARK: - Blocking acquisition

    public func readLock() {
        let result = pthread_rwlock_rdlock(rwlock)
        precondition(result == 0, "pthread_rwlock_rdlock failed: \(String(cString: strerror(result)))")
    }

    public func writeLock() {
        let result = pthread_rwlock_wrlock(rwlock)
        precondition(result == 0, "pthread_rwlock_wrlock failed: \(String(cString: strerror(result)))")
    }

    public func unlock() {
        let result = pthread_rwlock_unlock(rwlock)
        precondition(result == 0, "pthread_rwlock_unlock failed: \(String(cString: strerror(result)))")
    }

    public func tryReadLock() -> Bool {
        let result = pthread_rwlock_tryrdlock(rwlock)
        switch result {
        case 0: return true
        case EBUSY, EAGAIN: return false
        default:
            preconditionFailure("pthread_rwlock_tryrdlock failed: \(String(cString: strerror(result)))")
        }
    }

    public func tryWriteLock() -> Bool {
        let result = pthread_rwlock_trywrlock(rwlock)
        switch result {
        case 0: return true
        case EBUSY: return false
        default:
            preconditionFailure("pthread_rwlock_trywrlock failed: \(String(cString: strerror(result)))")
        }
    }

    @discardableResult
    public func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        readLock()
        defer { unlock() }
        return try body()
    }

    @discardableResult
    public func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        writeLock()
        defer { unlock() }
        return try body()
    }
}
