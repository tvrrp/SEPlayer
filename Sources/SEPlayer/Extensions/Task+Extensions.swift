//
//  Task+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import Foundation

extension Task where Success == Never, Failure == Never {
    @available(iOS, deprecated: 16.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(macOS, deprecated: 13.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(watchOS, deprecated: 9.0, renamed: "Task.sleep(for:tolerance:clock:)")
    @available(tvOS, deprecated: 16.0, renamed: "Task.sleep(for:tolerance:clock:)")
    public static func sleep(for interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .zero, queue: DispatchQueue? = nil) async throws {
        let queue = queue ?? DispatchQueue(label: "com.seplayer.timer", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: _Concurrency.CancellationError())
                    return
                }

                timer.schedule(
                    deadline: .now() + interval,
                    repeating: .never,
                    leeway: leeway
                )

                timer.setEventHandler {
                    continuation.resume()
                }

                timer.setCancelHandler {
                    continuation.resume(throwing: _Concurrency.CancellationError())
                }

                timer.activate()
            }
        } onCancel: {
            timer.cancel()
        }
    }
}

extension DispatchTimeInterval {
    public static var zero: DispatchTimeInterval { .nanoseconds(0) }
}
