//
//  CacheBudget.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import SEPlayerCommon

/// The memory the caches of the resources of one data source factory may hold together.
final class CacheBudget: @unchecked Sendable {
    let limit: Int

    var usedBytes: Int {
        lock.withLock { used }
    }

    /// Whether the system is short of memory: then a cache keeps only what it must.
    var isUnderPressure: Bool {
        lock.withLock { pressure.isUnderPressure }
    }

    private let lock = UnfairLock()
    private let pressure = MemoryPressure()
    private var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes `bytes` of the budget.
    ///
    /// - Parameter force: Takes them even past the limit.
    /// - Returns: Whether they were taken.
    func reserve(_ bytes: Int, force: Bool = false) -> Bool {
        lock.withLock {
            guard force || used + bytes <= limit else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        lock.withLock {
            assert(used >= bytes)
            used = max(0, used - bytes)
        }
    }
}
