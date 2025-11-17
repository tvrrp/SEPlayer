//
//  PlayerActor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.11.2025.
//

@testable import SEPlayer

nonisolated(unsafe) let playerConcurrentQueue = SignalQueue(concurrentQueueName: "com.seplayer.playerConcurrentQueue")
nonisolated(unsafe) let playerSyncQueue = SignalQueue(name: "com.seplayer.playerSyncQueue")

protocol PlayerActor: Actor {
    static func runOnActor(body: @Sendable () throws -> Void) async rethrows
}

@globalActor actor TestableConcurrentPlayerActor: GlobalActor, PlayerActor {
    static let shared = TestableConcurrentPlayerActor()
    private init() {}

    nonisolated let executor = PlayerConcurrentExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    static func run<T: Sendable>(resultType: T.Type = T.self, body: @TestableConcurrentPlayerActor @Sendable () throws -> T) async rethrows -> T {
        try await body()
    }

    static func runOnActor(body: @Sendable () throws -> Void) async rethrows {
        try await run(body: body)
    }
}

final class PlayerConcurrentExecutor: SerialExecutor {
    func enqueue(_ job: UnownedJob) {
        playerConcurrentQueue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

@globalActor actor TestableSyncPlayerActor: GlobalActor, PlayerActor {
    static let shared = TestableSyncPlayerActor()
    private init() {}

    nonisolated let executor = PlayerSyncExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public static func run<T>(resultType: T.Type = T.self, body: @TestableSyncPlayerActor @Sendable () throws -> T) async rethrows -> T where T : Sendable {
        try await body()
    }

    static func runOnActor(body: @Sendable () throws -> Void) async rethrows {
        try await run(body: body)
    }
}

final class PlayerSyncExecutor: SerialExecutor {
    func enqueue(_ job: UnownedJob) {
        playerSyncQueue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
