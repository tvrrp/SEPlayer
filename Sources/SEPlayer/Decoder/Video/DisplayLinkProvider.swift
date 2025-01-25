//
//  DisplayLinkProvider.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.01.2025.
//

import QuartzCore

protocol DisplayLinkProvider {
    var sampledVsyncTime: Int64? { get }
    var screenFrameRate: Int { get }
    func addOutput(_ output: SEPlayerBufferView)
    func removeOutput(_ output: SEPlayerBufferView)
    func addObserver()
    func removeObserver()
}

final class CADisplayLinkProvider: DisplayLinkProvider {
    var sampledVsyncTime: Int64? {
        assert(queue.isCurrent())
        if let _sampledVsyncTime {
            return Int64(_sampledVsyncTime * 1_000_000_000)
        }
        return nil
    }

    var screenFrameRate: Int {
        assert(queue.isCurrent())
        return _screenFrameRate
    }

    private let observers = MulticastDelegate<SEPlayerBufferView>()
    private let queue: Queue
    private var displayLink: CADisplayLink?

    private var observersCount: Int = 0
    private var _sampledVsyncTime: TimeInterval?
    private var _screenFrameRate: Int = 60
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

    func addOutput(_ output: SEPlayerBufferView) {
        assert(queue.isCurrent())
        observers.addDelegate(output)
        addObserver()
        updateScreenFrameRateIfNeeded()
    }

    func removeOutput(_ output: SEPlayerBufferView) {
        assert(queue.isCurrent())
        observers.removeDelegate(output)
        removeObserver()
    }

    private func startIfNeeded() {
        DispatchQueue.main.async { [self] in
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(onDisplayTick))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    private func removeIfNeeded() {
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
        queue.sync { _sampledVsyncTime = displayLink.timestamp }
        observers.invokeDelegates { $0.displayLinkTick(displayLink) }
        updateScreenFrameRateIfNeeded()
    }

    private func updateScreenFrameRateIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            let currentFrameRate = self.screenFrameRate
            var newFrameRate = currentFrameRate
            Queues.mainQueue.async {
                self.observers.invokeDelegates {
                    if let frameRate = $0.outputWindowScene?.screen.maximumFramesPerSecond {
                        newFrameRate = max(newFrameRate, frameRate)
                    }
                }
                if newFrameRate != currentFrameRate {
                    self.queue.async { self._screenFrameRate = newFrameRate }
                }
            }
        }
    }
}
