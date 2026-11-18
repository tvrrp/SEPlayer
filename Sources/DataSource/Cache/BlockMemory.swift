//
//  BlockMemory.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// The memory of one block of a ``BlockCache``.
///
/// Block buffers made from it pin it: it stays, non-volatile, until the last of them is released, even after the
/// cache removed the block.
final class BlockMemory: @unchecked Sendable {
    var pointer: UnsafeMutableRawPointer { memory.pointer }

    var size: Int { memory.size }

    var isPinned: Bool {
        lock.withLock { pinCount > 0 }
    }

    /// Whether the system purged the memory while it was volatile. Costs a system call.
    var isPurged: Bool {
        lock.withLock { appliedOrder != nil && memory.isPurged }
    }

    private let memory: PurgeableMemory
    private let lock = UnfairLock()

    private var pinCount = 0
    /// What the cache asked for: volatile in this order, or non-volatile for `nil`.
    private var requestedOrder: PurgeableMemory.Order?
    /// What the memory is now: volatile in this order, or non-volatile for `nil`.
    private var appliedOrder: PurgeableMemory.Order?

    init?(size: Int) {
        guard let memory = PurgeableMemory(size: size) else { return nil }

        self.memory = memory
    }

    /// Makes the memory volatile in `order`, or non-volatile for `nil`. Pinned memory stays non-volatile until it is
    /// unpinned.
    ///
    /// - Returns: `false` if the system purged the memory while it was volatile.
    func setVolatility(_ order: PurgeableMemory.Order?) -> Bool {
        lock.withLock {
            requestedOrder = order
            return applyRequestedVolatility()
        }
    }

    /// Keeps the memory, non-volatile, for a reader until ``unpin()``.
    ///
    /// - Returns: `false` if the system purged the memory while it was volatile. It is not pinned then.
    func pin() -> Bool {
        lock.withLock {
            if appliedOrder != nil {
                appliedOrder = nil
                guard memory.makeNonVolatile() else {
                    // The contents are gone, so the cache removes the block.
                    _ = applyRequestedVolatility()
                    return false
                }
            }
            pinCount += 1
            return true
        }
    }

    func unpin() {
        lock.withLock {
            assert(pinCount > 0)
            pinCount -= 1
            _ = applyRequestedVolatility()
        }
    }

    /// Appends `range` of the memory to `blockBuffer` without copying. The block buffer pins the memory until it is
    /// released.
    func append(_ range: Range<Int>, to blockBuffer: CMBlockBuffer) throws {
        guard pin() else {
            throw DataSourceError(reason: .unknown, message: "Appending memory the system purged")
        }

        do {
            try blockBuffer.appendMemoryBlock(
                UnsafeMutableRawBufferPointer(start: pointer + range.lowerBound, count: range.count),
                deallocator: { _, _ in self.unpin() }
            )
        } catch {
            unpin()
            throw error
        }
    }

    /// Must be called with the lock held.
    private func applyRequestedVolatility() -> Bool {
        let target = pinCount == 0 ? requestedOrder : nil
        guard target != appliedOrder else { return true }

        let wasVolatile = appliedOrder != nil
        appliedOrder = target
        if let target {
            memory.makeVolatile(target)
            return true
        }

        return wasVolatile ? memory.makeNonVolatile() : true
    }
}
