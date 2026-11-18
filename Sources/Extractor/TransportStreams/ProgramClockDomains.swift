//
//  ProgramClockDomains.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.08.2026.
//

import CoreMedia
import SEPlayerCommon

// TODO: rewrite this garbade
public final class ProgramClockDomains: @unchecked Sendable {
    private enum Storage {
        case unified(TimestampAdjuster.Session)
        case perProgram(primary: TimestampAdjuster)
    }

    private let lock = UnfairLock()
    private let storage: Storage

    private var byProgram: [Int: TimestampAdjuster.Session] = [:]
    private var secondaries: [TimestampAdjuster] = []

    public init(unified session: TimestampAdjuster.Session) {
        self.storage = .unified(session)
    }

    public init(perProgram primary: TimestampAdjuster) {
        self.storage = .perProgram(primary: primary)
    }

    public func session(forProgram programNumber: Int) -> TimestampAdjuster.Session {
        let existing = lock.usingLock { () -> TimestampAdjuster.Session? in
            switch storage {
            case let .unified(session): session
            case .perProgram: byProgram[programNumber]
            }
        }
        if let existing { return existing }

        guard case let .perProgram(primary) = storage else {
            preconditionFailure("unreachable: unified always returns above")
        }

        // Seed a secondary from the primary's mode, not from its resolved offset: each program
        // anchors on its own first DTS.
        let isFirst = lock.usingLock { byProgram.isEmpty }
        let adjuster = isFirst
            ? primary
            : TimestampAdjuster(mode: primary.mode)
        let session = adjuster.makeSession()

        return lock.usingLock {
            if let raced = byProgram[programNumber] { return raced }
            if !isFirst { secondaries.append(adjuster) }
            byProgram[programNumber] = session
            return session
        }
    }

    public var allSessions: [TimestampAdjuster.Session] {
        lock.usingLock {
            switch storage {
            case let .unified(session): [session]
            case .perProgram: Array(byProgram.values)
            }
        }
    }
}
