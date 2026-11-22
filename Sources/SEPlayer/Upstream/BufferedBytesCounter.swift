//
//  BufferedBytesCounter.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.upstream.Allocator
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import Foundation
import SEPlayerCommon

/// Counts the bytes of media the sample queues of a player hold, for the memory limit of the load control.
///
/// It takes the place of Media3's allocator: sample data references the buffers it was read into, so there is nothing
/// to allocate, only bytes to count.
public protocol BufferedBytesCounter: AnyObject, Sendable {
    /// The bytes held now.
    var bufferedBytes: Int { get }
    /// Records that `bytes` more are held.
    func add(bytes: Int)
    /// Records that `bytes` are no longer held.
    func remove(bytes: Int)
}

/// A ``BufferedBytesCounter`` that counts what the queues report, safely from any thread.
public final class DefaultBufferedBytesCounter: BufferedBytesCounter, @unchecked Sendable {
    public var bufferedBytes: Int {
        lock.withLock { bytes }
    }

    private let lock = UnfairLock()
    private var bytes = 0

    public init() {}

    public func add(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { self.bytes += bytes }
    }

    public func remove(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock {
            assert(self.bytes >= bytes, "Removed more bytes than were held")
            self.bytes = max(0, self.bytes - bytes)
        }
    }
}
