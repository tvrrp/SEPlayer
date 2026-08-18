//
//  TimebaseTimeObserver.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.07.2026.
//

import CoreMedia

final class TimebaseTimeObserver {
    private let queue: DispatchQueue
    private let dispatchSourceTimer: DispatchSourceTimer
    private let timebase: CMTimebase
    private let block: (CMTime) -> Void

    private var sourceType: SourceType

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

        dispatchSourceTimer = DispatchSource.makeTimerSource(queue: queue)
        dispatchSourceTimer.setEventHandler { [weak self] in
            guard let self else { return }
            block(timebase.time)
            start()
        }
        dispatchSourceTimer.resume()
        try timebase.addTimer(dispatchSourceTimer)
        start()
    }

    private func start() {
        let fireTime: CMTime

        switch sourceType {
        case let .periodic(time):
            fireTime = timebase.time + time
        case var .boundary(times):
            guard !times.isEmpty else { return }
            fireTime = times.removeFirst()
            sourceType = .boundary(times)
        }

        startTimer(for: fireTime)
    }

    private func startTimer(for time: CMTime) {
        try! timebase.setTimerNextFireTime(dispatchSourceTimer, fireTime: time)
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
