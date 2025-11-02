//
//  SimpleEventTimer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.09.2025.
//

import Foundation

final class SimpleEventTimer {
    private let queue: Queue
    private let timer: DispatchSourceTimer
    private var actionHandler: (() -> Void)?

    private var isSuspended: Bool = true
    private var jobsQueue = [DispatchTime]()

    init(queue: Queue) {
        self.queue = queue
        timer = DispatchSource.makeTimerSource(queue: queue.queue)
    }

    func setActionHandler(_ handler: (() -> Void)?) {
        assert(queue.isCurrent())
        self.actionHandler = handler
        suspendTimer()

        guard handler != nil else {
            timer.cancel()
            return
        }

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            actionHandler?()
            scheduleNextJobIfNeeded()
        }
    }

    func deactivate() {
        if isSuspended {
            timer.resume()
            isSuspended = true
        }

        timer.cancel()
    }

    func activateTimer() {
        assert(queue.isCurrent())
        guard isSuspended else { return }

        isSuspended = false
        timer.resume()
        scheduleNextJobIfNeeded()
    }

    func suspendTimer() {
        assert(queue.isCurrent())
        guard !isSuspended else { return }

        isSuspended = true
        timer.suspend()
    }

    func scheduleJob(deadline: DispatchTime) {
        assert(queue.isCurrent())
        jobsQueue.append(deadline)
        scheduleNextJobIfNeeded()
    }

    func cleanQueue() {
        assert(queue.isCurrent())
        jobsQueue.removeAll(keepingCapacity: true)
    }

    private func scheduleNextJobIfNeeded() {
        assert(queue.isCurrent())
        guard !isSuspended, !jobsQueue.isEmpty else { return }

        let nextJob = jobsQueue.removeFirst()
        if nextJob < .now() {
            actionHandler?()
        } else {
            timer.schedule(deadline: nextJob)
        }
    }
}
