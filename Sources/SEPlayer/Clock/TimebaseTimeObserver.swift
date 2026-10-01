//
//  TimebaseTimeObserver.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.07.2026.
//

import CoreMedia
import Foundation

final class TimebaseTimeObserver {
    private let queue: DispatchQueue
    private let dispatchSourceTimer: DispatchSourceTimer
    private let timebase: CMTimebase
    private let block: (CMTime) -> Void
    private let sourceType: SourceType
    private let boundaryTimes: [CMTime]
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        queue: DispatchQueue,
        timebase: CMTimebase,
        sourceType: SourceType,
        block: @escaping (CMTime) -> Void
    ) throws {
        self.queue = queue
        self.timebase = timebase
        self.sourceType = sourceType
        self.block = block
        if case let .boundary(times) = sourceType {
            boundaryTimes = times.sorted()
        } else {
            boundaryTimes = []
        }

        dispatchSourceTimer = DispatchSource.makeTimerSource(queue: queue)
        dispatchSourceTimer.setEventHandler { [weak self] in
            guard let self else { return }
            block(timebase.time)
            start()
        }
        dispatchSourceTimer.resume()
        try timebase.addTimer(dispatchSourceTimer)

        // A timer never fires for a time the timebase has already passed, so when the time jumps
        // (the player sets its start position, or seeks) the next fire time is worked out again.
        // A jump of the source timebase does not always reach this one as a jump, so a change of
        // rate — playback starting or stopping — does the same.
        notificationObservers = [CMTimebase.timeJumped, CMTimebase.effectiveRateChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: timebase, queue: nil) { [weak self] _ in
                queue.async { self?.start() }
            }
        }
        start()
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        try? timebase.removeTimer(dispatchSourceTimer)
        dispatchSourceTimer.cancel()
    }

    private func start() {
        let now = timebase.time
        let fireTime: CMTime

        switch sourceType {
        case let .periodic(interval):
            fireTime = now + interval
        case .boundary:
            // The first boundary still ahead; each one fires once as the time passes it.
            fireTime = boundaryTimes.first { $0 > now } ?? .invalid
        }
        try? timebase.setTimerNextFireTime(dispatchSourceTimer, fireTime: fireTime)
    }
}

extension TimebaseTimeObserver {
    enum SourceType {
        case periodic(CMTime)
        case boundary([CMTime])
    }
}

extension TimebaseTimeObserver: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func == (lhs: TimebaseTimeObserver, rhs: TimebaseTimeObserver) -> Bool {
        lhs === rhs
    }
}
