//
//  FakeClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import CoreMedia
import Testing
@testable import SEPlayer

final class FakeClock: SEClock {
    let timebase: CMTimebase? = nil

    var milliseconds: Int64 {
        lock.withLock {
            autoAdvance()
            return initialTimeMs
        }
    }
    var microseconds: Int64 {
        lock.withLock {
            autoAdvance()
            return Time.msToUs(timeMs: initialTimeMs)
        }
    }
    var nanoseconds: Int64 {
        lock.withLock {
            autoAdvance()
            return Time.msToUs(timeMs: initialTimeMs) * 1000
        }
    }

    private var initialTimeMs: Int64
    private let isAutoAdvancing: Bool
    private let lock: NSLock

    init(initialTimeMs: Int64 = 0, isAutoAdvancing: Bool = true) {
        self.initialTimeMs = initialTimeMs
        self.isAutoAdvancing = isAutoAdvancing
        lock = NSLock()
    }

    func advanceTime(timeDiffMs: Int64) {
        lock.withLock { initialTimeMs += timeDiffMs }
    }

    func setRate(_ rate: Double) throws {
        
    }

    func setTime(_ time: CMTime) throws {
        initialTimeMs = time.microseconds
    }

    private func autoAdvance() {
        if isAutoAdvancing {
            initialTimeMs += 100
        }
    }
}
