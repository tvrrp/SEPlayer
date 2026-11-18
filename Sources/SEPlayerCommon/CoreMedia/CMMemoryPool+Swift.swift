//
//  CMMemoryPool+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia
import Foundation

public extension _CoreMediaInitializable where Self == CMMemoryPool {
    /// A pool of memory for block buffers: memory freed to it is kept for reuse until it is unused for
    /// `ageOutPeriod` seconds.
    init(ageOutPeriod: TimeInterval? = nil) {
        let options = ageOutPeriod.map { [kCMMemoryPoolOption_AgeOutPeriod: $0] as CFDictionary }
        self = CMMemoryPoolCreate(options: options)
    }
}

public extension CMMemoryPool {
    /// Allocates from the pool, for block buffers and other Core Foundation allocations.
    var allocator: CFAllocator {
        CMMemoryPoolGetAllocator(self)
    }

    /// Frees the memory the pool keeps.
    func flush() {
        CMMemoryPoolFlush(self)
    }

    /// Stops the pool from keeping memory; its allocator then allocates directly.
    func invalidate() {
        CMMemoryPoolInvalidate(self)
    }
}
