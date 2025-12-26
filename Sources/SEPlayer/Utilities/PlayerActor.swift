//
//  PlayerActor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.11.2025.
//

public actor PlayerActor {
    nonisolated public let executor: PlayerExecutor
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(executor: PlayerExecutor) {
        self.executor = executor
    }

    public func run<T: Sendable>(body: @Sendable (isolated any Actor) async throws -> T) async rethrows -> T {
        try await body(self)
    }
}

public final class PlayerExecutor: SerialExecutor {
    private nonisolated let queue: Queue
    public init(queue: Queue) { self.queue = queue }

    public func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
