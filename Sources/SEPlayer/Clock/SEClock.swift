//
//  SEClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import AVFoundation

@frozen public enum TimebaseSource: Equatable {
    case cmTimebase(CMTimebase)
    case renderSynchronizer(AVSampleBufferRenderSynchronizer)

    public static func == (lhs: TimebaseSource, rhs: TimebaseSource) -> Bool {
        switch (lhs, rhs) {
        case (.cmTimebase(let lhsTimebase), .cmTimebase(let rhsTimebase)):
            return lhsTimebase === rhsTimebase
        case (.renderSynchronizer(let lhsRenderSynchronizer), .renderSynchronizer(let rhsRenderSynchronizer)):
            return lhsRenderSynchronizer === rhsRenderSynchronizer
        default:
            return false
        }
    }
}

public protocol SEClock {
    var milliseconds: Int64 { get }
    var microseconds: Int64 { get }
    var nanoseconds: Int64 { get }

    var timebase: TimebaseSource? { get }

    func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper
    func setRate(_ rate: Double) throws
    func setTime(_ time: CMTime) throws
}

public struct DefaultSEClock: SEClock {
    public let timebase: TimebaseSource?
    private let clock: CMClock

    public var milliseconds: Int64 { clock.milliseconds }
    public var microseconds: Int64 { clock.microseconds }
    public var nanoseconds: Int64 { clock.nanoseconds }

    init() {
        clock = CMClockGetHostTimeClock()
        timebase = try? .cmTimebase(CMTimebase(sourceClock: clock))
    }

    public func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper {
        DefaultHandlerWrapper(handler: Handler(queue: queue, looper: looper))
    }

    public func setRate(_ rate: Double) throws {
        guard let timebase else { return }
        switch timebase {
        case let .cmTimebase(timebase):
            try timebase.setRate(rate)
        case let .renderSynchronizer(renderSynchronizer):
            renderSynchronizer.setRate(Float(rate), time: renderSynchronizer.currentTime())
        }
    }

    public func setTime(_ time: CMTime) throws {
        guard let timebase else { return }
        switch timebase {
        case let .cmTimebase(timebase):
            try timebase.setTime(time)
        case let .renderSynchronizer(renderSynchronizer):
            renderSynchronizer.setRate(renderSynchronizer.rate, time: time)
        }
    }
}
