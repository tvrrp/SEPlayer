//
//  SEClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import CoreMedia

public protocol SEClock {
    var milliseconds: Int64 { get }
    var microseconds: Int64 { get }
    var nanoseconds: Int64 { get }

    var timebase: CMTimebase? { get }

    func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper
    func setRate(_ rate: Double) throws
    func setTime(_ time: CMTime) throws
}

public struct DefaultSEClock: SEClock {
    public let timebase: CMTimebase?
    private let clock: CMClock

    public var milliseconds: Int64 { clock.milliseconds }
    public var microseconds: Int64 { clock.microseconds }
    public var nanoseconds: Int64 { clock.nanoseconds }

    init() {
        clock = CMClockGetHostTimeClock()
        timebase = try? CMTimebase(sourceClock: clock)
    }

    public func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper {
        DefaultHandlerWrapper(handler: Handler(queue: queue, looper: looper))
    }

    public func setRate(_ rate: Double) throws {
        try timebase?.setRate(rate)
    }

    public func setTime(_ time: CMTime) throws {
        try timebase?.setTime(time)
    }
}
