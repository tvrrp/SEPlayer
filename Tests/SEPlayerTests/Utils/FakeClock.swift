//
//  FakeClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import CoreMedia
import SEPlayerCommon
import Testing
@testable import SEPlayer

final class FakeClock: SEClock, @unchecked Sendable {
    let clock: CMClock = CMClock.hostTimeClock

    var time: CMTime {
        CMTime(value: milliseconds, timescale: 1000)
    }

    static let mediaTimeRate: Float64 = 30

    private let mediaTimeSource: CMTimebase = {
        let timebase = try! CMTimebase(sourceClock: CMClock.hostTimeClock)
        try! timebase.setTime(to: .zero)
        try! timebase.setRate(to: FakeClock.mediaTimeRate)
        return timebase
    }()

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

    init(bootTimeMs: Int64 = 0, initialTimeMs: Int64 = 0) {
        self.bootTimeMs = bootTimeMs
        self.timeSinceBootMs = initialTimeMs
        lock = UnfairLock()
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
