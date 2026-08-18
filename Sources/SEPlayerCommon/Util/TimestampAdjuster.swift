//
//  TimestampAdjuster.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

import CoreMedia
import Foundation

public final class TimestampAdjuster: @unchecked Sendable {
    public enum Mode: Sendable {
        case noOffset
        case firstSampleAt(CMTime)
        case shared
    }

    public struct TimeoutError: Error, Sendable {
        public let interval: DispatchTimeInterval
    }

    let lock: UnfairLock

    public var mode: Mode
    private var offset: CMTime?
    private var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextWaiterID: UInt64 = 0

    public init(mode: Mode, sharingLockWith other: TimestampAdjuster? = nil) {
        self.lock = other?.lock ?? UnfairLock()
        self.mode = mode
        if case .noOffset = mode { self.offset = .zero }
    }

    public func makeSession(desiredFirstSampleTime: CMTime = .zero) -> Session {
        lock.usingLock {
            switch mode {
            case .noOffset:
                return Session(adjuster: self, desiredFirstSampleTime: nil)
            case .firstSampleAt(let time):
                return Session(adjuster: self, desiredFirstSampleTime: time)
            case .shared:
                return Session(adjuster: self, desiredFirstSampleTime: desiredFirstSampleTime)
            }
        }
    }

    public func awaitOffset(timeout: DispatchTimeInterval? = nil) async throws {
        guard lock.usingLock({ offset }) == nil else { return }
        guard let timeout else { return try await wait() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError(interval: timeout)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    public func reset(mode newMode: Mode) {
        let pending = lock.usingLock { resetLocked(mode: newMode) }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    var offsetLocked: CMTime? { offset }

    var modeLocked: Mode { mode }

    func establishLocked(
        offset candidate: CMTime
    ) -> (offset: CMTime, waiters: [CheckedContinuation<Void, Error>]) {
        if let offset { return (offset, []) }
        offset = candidate
        let pending = Array(waiters.values)
        waiters.removeAll()
        return (candidate, pending)
    }

    func resetLocked(mode newMode: Mode) -> [CheckedContinuation<Void, Error>] {
        mode = newMode
        if case .noOffset = newMode { offset = .zero } else { offset = nil }
        let pending = Array(waiters.values)
        waiters.removeAll()
        return pending
    }

    private func wait() async throws {
        let id = lock.usingLock { () -> UInt64 in
            nextWaiterID += 1
            return nextWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                enum Immediate { case none, ready, cancelled }

                let immediate: Immediate = lock.usingLock {
                    if offset != nil { return .ready }
                    if Task.isCancelled { return .cancelled }
                    waiters[id] = cont
                    return .none
                }

                switch immediate {
                case .ready: cont.resume()
                case .cancelled: cont.resume(throwing: CancellationError())
                case .none: break
                }
            }
        } onCancel: {
            let cont = lock.usingLock { waiters.removeValue(forKey: id) }
            cont?.resume(throwing: CancellationError())
        }
    }
}

public extension TimestampAdjuster {
    final class Session: @unchecked Sendable {
        private static let tsTimescale: CMTimeScale = 90_000

        private let adjuster: TimestampAdjuster

        private var unwrapper = PtsUnwrapper()
        private var offset: CMTime?
        private var desired: CMTime?

        fileprivate init(adjuster: TimestampAdjuster, desiredFirstSampleTime: CMTime?) {
            self.adjuster = adjuster
            self.desired = desiredFirstSampleTime
        }

        public func adjust(_ time: CMTime) -> CMTime {
            guard time.isNumeric else { return time }
            return withResolvedOffset(observing: time) { offset in
                CMTimeAdd(time, offset)
            }
        }

        public func adjustTS(pts33: Int64, dts33: Int64?) -> (pts: CMTime, dts: CMTime) {
            adjuster.lock.usingLock { () -> (CMTime, CMTime) in
                let dtsTicks = unwrapper.unwrap(dts33 ?? pts33)
                let ptsTicks = pts33 + (dtsTicks - (dts33 ?? pts33))

                let dts = CMTime(value: dtsTicks, timescale: Self.tsTimescale)
                let pts = CMTime(value: ptsTicks, timescale: Self.tsTimescale)
                let offset = resolveOffsetLocked(observing: dts)
                return (CMTimeAdd(pts, offset), CMTimeAdd(dts, offset))
            }
        }

        public var hasEstablishedOffset: Bool {
            adjuster.lock.usingLock { offset ?? adjuster.offsetLocked } != nil
        }

        public var desiredFirstSampleTime: CMTime? {
            adjuster.lock.usingLock { desired }
        }

        public func reset(desiredFirstSampleTime time: CMTime) {
            let pending: [CheckedContinuation<Void, Error>] = adjuster.lock.usingLock {
                offset = nil
                desired = time
                unwrapper.reset()
                return adjuster.resetLocked(mode: .firstSampleAt(time))
            }
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }

        private func withResolvedOffset(
            observing first: CMTime,
            _ body: (CMTime) -> CMTime
        ) -> CMTime {
            adjuster.lock.usingLock {
                body(resolveOffsetLocked(observing: first))
            }
        }

        private func resolveOffsetLocked(observing first: CMTime) -> CMTime {
            if let offset { return offset }
            let candidate = CMTimeSubtract(desired ?? .zero, first)
            let established = adjuster.establishLocked(offset: candidate)
            offset = established.offset
            established.waiters.forEach { $0.resume() }
            return established.offset
        }
    }
}

public extension TimestampAdjuster {
    static func passthroughSession() -> Session {
        TimestampAdjuster(mode: .noOffset).makeSession()
    }

    static func firstSampleAtZeroSession() -> Session {
        TimestampAdjuster(mode: .firstSampleAt(.zero)).makeSession()
    }
}
