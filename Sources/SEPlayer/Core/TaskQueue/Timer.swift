//
//  Timer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.01.2025.
//

import Foundation

final class Timer {
    // MARK: - Properties

    private var timer: DispatchSourceTimer?
    private let timeout: Double
    private let fireOnStart: Bool
    private let `repeat`: Bool
    private let completion: () -> Void
    private let onInvalidation: (() -> Void)?
    private let queue: Queue

    // MARK: - Init

    init(timeout: Double, fireOnStart: Bool = false, `repeat`: Bool, completion: @escaping () -> Void, onInvalidation: (() -> Void)? = nil, queue: Queue) {
        self.timeout = timeout
        self.fireOnStart = fireOnStart
        self.`repeat` = `repeat`
        self.completion = completion
        self.onInvalidation = onInvalidation
        self.queue = queue
    }

    deinit {
        invalidate()
    }

    // MARK: - Interface

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue.queue)
        timer.setEventHandler(handler: { [weak self] in
            guard let self = self else { return }

            self.completion()
            if !self.`repeat` {
                self.invalidate()
            }
        })

        self.timer = timer

        if fireOnStart {
            completion()
        }

        if `repeat` {
            let time = DispatchTime.now() + timeout
            timer.schedule(deadline: time, repeating: timeout)
        } else {
            let time = DispatchTime.now() + timeout
            timer.schedule(deadline: time)
        }

        timer.resume()
    }

    func invalidate() {
        timer?.cancel()
        self.timer = nil

        onInvalidation?()
    }
}
