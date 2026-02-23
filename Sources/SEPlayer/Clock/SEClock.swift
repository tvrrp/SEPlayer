//
//  SEClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import AVFoundation

public protocol SEClock {
    var clock: CMClock { get }
    var milliseconds: Int64 { get }
    var microseconds: Int64 { get }
    var nanoseconds: Int64 { get }

    func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper
}

public struct DefaultSEClock: SEClock {
    static let shared: SEClock = DefaultSEClock()

    public let clock: CMClock

    public var milliseconds: Int64 { clock.milliseconds }
    public var microseconds: Int64 { clock.microseconds }
    public var nanoseconds: Int64 { clock.nanoseconds }

    init() {
        clock = CMClockGetHostTimeClock()
    }

    public func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper {
        DefaultHandlerWrapper(handler: Handler(queue: queue, looper: looper))
    }
}
