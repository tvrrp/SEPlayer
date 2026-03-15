//
//  SignalQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

@preconcurrency import Foundation

private let QueueSpecificKey = DispatchSpecificKey<NSObject>()
private let ActorSpecificKey = DispatchSpecificKey<ActorWeakWrapper>()

private let globalMainQueue = SignalQueue(queue: DispatchQueue.main, specialIsMainQueue: true)
private let globalDefaultQueue = SignalQueue(queue: DispatchQueue.global(qos: .default), specialIsMainQueue: false)
private let globalBackgroundQueue = SignalQueue(queue: DispatchQueue.global(qos: .background), specialIsMainQueue: false)

public final class SignalQueue: Queue, Sendable {
    // MARK: - Class

    public static func mainQueue() -> Queue {
        globalMainQueue
    }

    public static func concurrentDefaultQueue() -> Queue {
        globalDefaultQueue
    }

    public static func concurrentBackgroundQueue() -> Queue {
        globalBackgroundQueue
    }

    // MARK: - Properties

    public var queue: DispatchQueue { nativeQueue }

    private let nativeQueue: DispatchQueue
    private nonisolated(unsafe) let specific = NSObject()
    private let specialIsMainQueue: Bool

    // MARK: - Init

    public init(queue: DispatchQueue) {
        nativeQueue = queue
        specialIsMainQueue = false
    }

    fileprivate init(queue: DispatchQueue, specialIsMainQueue: Bool) {
        nativeQueue = queue
        self.specialIsMainQueue = specialIsMainQueue
    }

    public init(name: String? = nil, qos: DispatchQoS = .default) {
        nativeQueue = DispatchQueue(label: name ?? "", qos: qos)

        specialIsMainQueue = false

        nativeQueue.setSpecific(key: QueueSpecificKey, value: specific)
    }

    // MARK: - Interface

    public func isCurrent() -> Bool {
        if DispatchQueue.getSpecific(key: QueueSpecificKey) === specific {
            return true
        } else if specialIsMainQueue && Thread.isMainThread {
            return true
        } else {
            return false
        }
    }

    public func playerActor() -> PlayerActor {
        if let playerActor = nativeQueue.getSpecific(key: ActorSpecificKey)?.playerActor {
            return playerActor
        } else {
            let playerActor = PlayerActor(executor: .init(queue: self))
            nativeQueue.setSpecific(key: ActorSpecificKey, value: .init(playerActor))
            return playerActor
        }
    }

    public func async(_ f: @escaping @Sendable () -> Void) {
        if isCurrent() {
            f()
        } else {
            nativeQueue.async(execute: f)
        }
    }

    public func execute(_ f: @escaping @Sendable () async -> Void) {
        Task { await executeInternally(f, isolation: playerActor()) }
    }

    public func sync<T>(_ f: () -> T) -> T {
        if isCurrent() {
            return f()
        } else {
            return nativeQueue.sync(execute: f)
        }
    }
    
    public func sync<T>(_ f: () throws -> T) rethrows -> T {
        if isCurrent() {
            return try! f()
        } else {
            return try! nativeQueue.sync(execute: f)
        }
    }

    public func justDispatch(_ f: @escaping @Sendable () -> Void) {
        nativeQueue.async(qos: nativeQueue.qos, flags: .detached, execute: f)
    }

    public func justDispatchWithQoS(qos: DispatchQoS, _ f: @escaping @Sendable () -> Void) {
        nativeQueue.async(qos: qos, flags: [.enforceQoS, .detached], execute: f)
    }

    public func after(_ delay: Double, _ f: @escaping @Sendable () -> Void) {
        let time = DispatchTime.now() + delay
        nativeQueue.asyncAfter(deadline: time, execute: f)
    }

    private func executeInternally(_ f: @escaping @Sendable () async -> Void, isolation: isolated PlayerActor) async {
        assert(isCurrent())
        await f()
    }
}

private final class ActorWeakWrapper: Sendable {
    nonisolated(unsafe) weak var playerActor: PlayerActor?

    init(_ playerActor: PlayerActor) {
        self.playerActor = playerActor
    }
}
