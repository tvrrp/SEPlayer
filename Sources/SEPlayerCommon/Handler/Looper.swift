//
//  Looper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2025.
//

import Dispatch

private let looperKey = DispatchSpecificKey<Looper>()

public final class Looper: Sendable {
    public let messageQueue: MessageQueue
    private let playerActor: PlayerActor

    public init(queue: Queue) {
        self.playerActor = queue.playerActor()
        messageQueue = MessageQueue()
    }

    deinit { quit() }

    public func quit() { messageQueue.quit(safe: false) }
    public func quitSafely() { messageQueue.quit(safe: true) }

    public static func myLooper(for queue: Queue) -> Looper {
        if let looper = queue.queue.getSpecific(key: looperKey) {
            return looper
        } else {
            let looper = Looper(queue: queue)
            queue.queue.setSpecific(key: looperKey, value: looper)
            looper.loop()
            return looper
        }
    }

    private func loopOnce(isolation: isolated any Actor) async -> Bool {
        do {
            guard let message = try await messageQueue.next() else {
                return false
            }

//            message.pointee.target?.dispatchMessage(msg: message)
//            Message.recycleUnchecked(message)
            message.target?.dispatchMessage(msg: message)
            message.recycleUnchecked()
            return true
        } catch {
            return false
        }
    }

    public func loop() {
        Task { [weak self] in
            guard let self else { return }

            while true {
                if await !loopOnce(isolation: playerActor) {
                    return
                }
            }
        }
    }
}
