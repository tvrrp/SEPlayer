//
//  PlayerActor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 03.11.2025.
//

@testable import SEPlayer

nonisolated(unsafe) let playerSyncQueue = SignalQueue(name: "com.seplayer.playerSyncQueue")

protocol TestPlayerActor: Actor {
    static func runOnActor(body: @Sendable () throws -> Void) async rethrows
}

@globalActor actor TestableSyncPlayerActor: GlobalActor, TestPlayerActor {
    static let shared = TestableSyncPlayerActor()
    private init() {}

    nonisolated let executor = TestPlayerSyncExecutor()
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

final class TestPlayerSyncExecutor: SerialExecutor {
    func enqueue(_ job: UnownedJob) {
        playerSyncQueue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
