//
//  SEClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import AVFoundation
import SEPlayerCommon

public protocol SEClock {
    var clock: CMClock { get }
    var time: CMTime { get }
    var milliseconds: Int64 { get }
    var microseconds: Int64 { get }
    var nanoseconds: Int64 { get }

    /// What runs the player's work on `queue`.
    func makeScheduler(queue: Queue) -> PlayerScheduler
    /// A timebase for media time to run on, following this clock.
    func makeTimebase() throws -> CMTimebase
    /// Whether media time runs on the player's render synchronizer, which follows the audio clock. A clock whose
    /// timebases run apart from it, as faster than real time, keeps media time on ``makeTimebase()``.
    var runsOnRenderSynchronizer: Bool { get }
}

public extension SEClock {
    func makeTimebase() throws -> CMTimebase {
        try CMTimebase(sourceClock: clock)
    }

    var runsOnRenderSynchronizer: Bool { true }
}

public struct DefaultSEClock: SEClock {
    static let shared: SEClock = DefaultSEClock()

    public let clock: CMClock

    public var time: CMTime { clock.time }
    public var milliseconds: Int64 { clock.milliseconds }
    public var microseconds: Int64 { clock.microseconds }
    public var nanoseconds: Int64 { clock.nanoseconds }

    init() {
        clock = CMClock.hostTimeClock
    }

    public func makeScheduler(queue: Queue) -> PlayerScheduler {
        DispatchPlayerScheduler(queue: queue)
    }
}
