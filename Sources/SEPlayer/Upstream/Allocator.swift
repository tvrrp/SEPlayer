//
//  Allocator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation
import SEPlayerCommon

/// Counts the bytes of media the sample queues of a player hold, for the memory limit of the load control.
///
/// Sample data references the buffers it was read into rather than copies of them, so there is nothing to allocate
/// here: the queues report what they hold.
public protocol Allocator: AnyObject, Sendable {
    /// The bytes held now.
    var totalBytesAllocated: Int { get }
    /// Records that `bytes` more are held.
    func allocate(bytes: Int)
    /// Records that `bytes` are no longer held.
    func release(bytes: Int)
}

final class DefaultAllocator: Allocator, @unchecked Sendable {
    var totalBytesAllocated: Int {
        lock.withLock { bytes }
    }

    private let lock = UnfairLock()
    private var bytes = 0

    func allocate(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { self.bytes += bytes }
    }

    func release(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock {
            assert(self.bytes >= bytes, "Released more bytes than were held")
            self.bytes = max(0, self.bytes - bytes)
        }
    }
}
