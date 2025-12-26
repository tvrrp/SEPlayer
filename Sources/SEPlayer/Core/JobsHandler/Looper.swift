//
//  Looper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2025.
//

import Dispatch

private let looperKey = DispatchSpecificKey<Looper>()

public final class Looper: Sendable {
    let messageQueue: MessageQueue
    private let playerActor: PlayerActor

    init(queue: Queue) {
        self.playerActor = queue.playerActor()
        messageQueue = MessageQueue()
    }

    deinit { quit() }

    func quit() { messageQueue.quit(safe: false) }
    func quitSafely() { messageQueue.quit(safe: true) }

    static func myLooper(for queue: Queue) -> Looper {
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

            message.pointee.target?.dispatchMessage(msg: message)
            Message.recycleUnchecked(message)
            return true
        } catch {
            return false
        }
    }

    func loop() {
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
