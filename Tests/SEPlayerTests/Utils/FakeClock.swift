//
//  FakeClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.test.utils.FakeClock
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
@testable import SEPlayer
import SEPlayerCommon
import Testing

final class FakeClock: SEClock, @unchecked Sendable {
    let clock: CMClock = .hostTimeClock

    var time: CMTime {
        CMTime(value: milliseconds, timescale: 1000)
    }

    static let mediaTimeRate: Float64 = 30

    private let mediaTimeSource: CMTimebase

    func makeTimebase() throws -> CMTimebase {
        try CMTimebase(sourceTimebase: mediaTimeSource)
    }

    var runsOnRenderSynchronizer: Bool { false }

    var milliseconds: Int64 {
        lock.withLock { bootTimeMs + timeSinceBootMs }
    }

    var microseconds: Int64 {
        Time.msToUs(timeMs: milliseconds)
    }

    var nanoseconds: Int64 {
        Time.msToUs(timeMs: milliseconds) * 1000
    }

    private var bootTimeMs: Int64
    private var timeSinceBootMs: Int64
    private let lock: UnfairLock

    init(bootTimeMs: Int64 = 0, initialTimeMs: Int64 = 0) throws {
        self.bootTimeMs = bootTimeMs
        self.timeSinceBootMs = initialTimeMs
        lock = UnfairLock()
        mediaTimeSource = try CMTimebase(sourceClock: CMClock.hostTimeClock)
        try mediaTimeSource.setTime(to: .zero)
        try mediaTimeSource.setRate(to: FakeClock.mediaTimeRate)
    }

    func advanceTime(_ timeDiffMs: Int64) {
        lock.withLock { timeSinceBootMs += timeDiffMs }
    }

    /// Moves the time forward to `milliseconds`, if it is behind.
    fileprivate func advanceTime(to milliseconds: Int64) {
        lock.withLock { timeSinceBootMs = max(timeSinceBootMs, milliseconds - bootTimeMs) }
    }

    func makeScheduler(queue: Queue) -> PlayerScheduler {
        FakeScheduler(queue: queue, clock: self)
    }
}

/// Runs the player's work on its queue, but only once the main queue is free, in the order it was posted: a test on the
/// main actor sees the player's state as its commands left it until it awaits. Delayed work runs as soon as it is
/// reached, moving the time of the clock forward to when it was due: the tests don't wait for timers.
private final class FakeScheduler: PlayerScheduler, @unchecked Sendable {
    private let queue: Queue
    private let clock: FakeClock

    init(queue: Queue, clock: FakeClock) {
        self.queue = queue
        self.clock = clock
    }

    func post(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async { [queue] in queue.justDispatch(work) }
    }

    func post(after delay: DispatchTimeInterval, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let dueMs = clock.milliseconds + Int64(delay.totalMilliseconds)
        let item = DispatchWorkItem(block: work)
        post { [clock] in
            guard !item.isCancelled else { return }
            clock.advanceTime(to: dueMs)
            item.perform()
        }
        return item
    }
}
