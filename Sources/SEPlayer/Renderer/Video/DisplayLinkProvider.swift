//
//  DisplayLinkProvider.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import UIKit

protocol DisplayLinkProvider {
    var sampledVsyncTime: Int64? { get }
    var vsyncDuration: Int64? { get }
    func addOutput(_ output: DisplayLinkListener)
    func removeOutput(_ output: DisplayLinkListener)
    func addObserver()
    func removeObserver()
}

protocol DisplayLinkListener: AnyObject {
    func displayLinkTick(_ info: DisplayLinkInfo)
}

struct DisplayLinkInfo {
    let currentTimestampNs: Int64
    let targetTimestampNs: Int64
}

final class CADisplayLinkProvider: DisplayLinkProvider {
    var sampledVsyncTime: Int64? {
        lock()
        let value = _sampledVsyncTime
        unlock()
        return value
    }

    var vsyncDuration: Int64? {
        lock()
        let value = _vsyncDuration
        unlock()
        return value
    }

    private let observers = MulticastDelegate<DisplayLinkListener>()
    private let queue: Queue
    private var displayLink: CADisplayLink?

    private var isStarted: Bool = false
    private let startCondition = NSCondition()
    private var observersCount: Int = 0
    private var _sampledVsyncTime: Int64?
    private var _vsyncDuration: Int64?
    private var onDisplayLinkExecuting: Bool = false

    init(queue: Queue) {
        self.queue = queue
    }

    func addObserver() {
        assert(queue.isCurrent())
        observersCount += 1
        if observersCount > 0 {
            startIfNeeded()
        }
    }

    func removeObserver() {
        assert(queue.isCurrent())
        observersCount -= 1
        if observersCount == 0 {
            removeIfNeeded()
            _sampledVsyncTime = nil
        }
    }

    func addOutput(_ output: DisplayLinkListener) {
        assert(queue.isCurrent())
        observers.addDelegate(output)
    }

    func removeOutput(_ output: DisplayLinkListener) {
        assert(queue.isCurrent())
        observers.removeDelegate(output)
    }

    private func startIfNeeded() {
        guard !isStarted else { return }
        DispatchQueue.main.async { [self] in
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(onDisplayTick))
            displayLink?.add(to: .main, forMode: .common)
        }
        startCondition.wait()
        isStarted = true
    }

    private func removeIfNeeded() {
        guard isStarted else { return }
        isStarted = false
        DispatchQueue.main.async { [self] in
            guard let displayLink else { return }
            displayLink.invalidate()
            self.displayLink = nil
        }
    }

    @objc private func onDisplayTick(_ displayLink: CADisplayLink) {
        guard !onDisplayLinkExecuting else { return }
        onDisplayLinkExecuting = true
        defer { onDisplayLinkExecuting = false }

        startCondition.signal()
        let currentTimestampNs = displayLink.timestamp.nanosecondsPerSecond
        let targetTimestampNs = displayLink.targetTimestamp.nanosecondsPerSecond
        let duration = displayLink.duration.nanosecondsPerSecond

        lock()
        self._sampledVsyncTime = targetTimestampNs
        self._vsyncDuration = duration
        unlock()

        observers.invokeDelegates {
            $0.displayLinkTick(.init(
                currentTimestampNs: currentTimestampNs,
                targetTimestampNs: targetTimestampNs
            ))
        }
    }

    private var unfairLock = os_unfair_lock_s()
    func lock() {
        os_unfair_lock_lock(&unfairLock)
    }

    func unlock() {
        os_unfair_lock_unlock(&unfairLock)
    }
}
