//
//  Task+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import Foundation

public extension Task where Success == Never, Failure == Never {
    @available(iOS, deprecated: 16.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(macOS, deprecated: 13.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(watchOS, deprecated: 9.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(tvOS, deprecated: 16.0, renamed: "Task.sleep(for:tolerance:clock:)")
    static func sleep(for interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .zero, queue: DispatchQueue? = nil) async throws {
        let queue = queue ?? DispatchQueue(label: "com.seplayer.timer", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var resumed = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The timer is activated even when the task is already cancelled: releasing a source that was never
                // activated traps. A cancel that came first runs the cancel handler once the timer is activated.
                timer.schedule(
                    deadline: .now() + interval,
                    repeating: .never,
                    leeway: leeway
                )

                timer.setEventHandler {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }

                timer.setCancelHandler {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: _Concurrency.CancellationError())
                }

                timer.activate()
            }
        } onCancel: {
            timer.cancel()
        }
    }
}

public extension DispatchTimeInterval {
    static var zero: DispatchTimeInterval { .nanoseconds(0) }
}
