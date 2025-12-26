//
//  Message.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.11.2025.
//

import Foundation

public protocol MessageKind {
    func isEqual(to other: MessageKind) -> Bool
}

struct EmptyMessageKind: MessageKind {
    func isEqual(to other: MessageKind) -> Bool {
        other is EmptyMessageKind
    }
}

private final class Pool {
    static let shared = Pool(capacity: 100)

    private let lock = UnfairLock()
    private let poolCapacity: Int
    private let storage: UnsafeMutablePointer<Message>
    private var freeHead: UnsafeMutablePointer<Message>? = nil

    init(capacity: Int) {
        self.poolCapacity = capacity
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: Message(), count: capacity)

        for i in 0..<(capacity - 1) {
            storage.advanced(by: i).pointee.next = storage.advanced(by: i + 1)
        }
        storage.advanced(by: capacity - 1).pointee.next = nil
        freeHead = storage
    }

    deinit {
        storage.deinitialize(count: poolCapacity)
        storage.deallocate()
    }

    func acquire() -> UnsafeMutablePointer<Message> {
        lock.lock(); defer { lock.unlock() }

        if let node = freeHead {
            freeHead = node.pointee.next
            node.pointee.next = nil
            return node
        }

        let p = UnsafeMutablePointer<Message>.allocate(capacity: 1)
        p.initialize(to: Message())
        return p
    }

    func release(_ p: UnsafeMutablePointer<Message>) {
        lock.lock(); defer { lock.unlock() }

        if isFromPool(p) {
            p.pointee = Message()
            p.pointee.next = freeHead
            freeHead = p
        } else {
            p.deinitialize(count: 1)
            p.deallocate()
        }
    }

    private func isFromPool(_ p: UnsafeMutablePointer<Message>) -> Bool {
        let base = UnsafeRawPointer(storage)
        let end  = base + poolCapacity * MemoryLayout<Message>.stride
        let addr = UnsafeRawPointer(p)

        guard addr >= base && addr < end else { return false }

        let offset = base.distance(to: addr)
        return offset % MemoryLayout<Message>.stride == 0
    }
}

public final class Message {
    var what: MessageKind = EmptyMessageKind()
    var inUse = false
    var whenNs: UInt64 = .zero
    var target: Handler?
    var callback: (() -> Void)?
    var next: UnsafeMutablePointer<Message>?

    fileprivate init() {}

    public static func obtain(
        handler: Handler? = nil,
        what: MessageKind? = nil
    ) -> UnsafeMutablePointer<Message> {
        let message = obtain()
        message.pointee.target = handler
        message.pointee.what = what ?? EmptyMessageKind()
        return message
    }

    public static func obtain() -> UnsafeMutablePointer<Message> {
        Pool.shared.acquire()
    }

    public static func recycle(_ pointer: UnsafeMutablePointer<Message>) {
        if pointer.pointee.inUse {
            assertionFailure(); return
        }

        recycleUnchecked(pointer)
    }

    static func recycleUnchecked(_ pointer: UnsafeMutablePointer<Message>) {
        pointer.pointee.inUse = true
        pointer.pointee.what = EmptyMessageKind()
        pointer.pointee.target = nil
        pointer.pointee.callback = nil

        Pool.shared.release(pointer)
    }

    public static func sendToTarget(_ pointer: UnsafeMutablePointer<Message>) {
        pointer.pointee.target?.sendMessage(pointer)
    }
}

//public final class Message {
//    var what: MessageKind = EmptyMessageKind()
//    var inUse = false
//    var whenNs: UInt64 = .zero
//    var target: Handler?
//    var callback: (() -> Void)?
//    var next = UnsafeMutablePointer<Message?>.allocate(capacity: 1)
//
//    private static let lock = UnfairLock()
//    private static var pool = UnsafeMutablePointer<Message?>.allocate(capacity: 1)
//    private static var poolSize: Int = .zero
//
//    private init() {}
//
//    public static func obtain(
//        handler: Handler? = nil,
//        what: MessageKind? = nil
//    ) -> UnsafeMutablePointer<Message> {
//        let msg = obtain()
//        msg.pointee.target = handler
//        msg.pointee.what = what ?? EmptyMessageKind()
//        return msg
//    }
//
//    public static func obtain() -> UnsafeMutablePointer<Message> {
//        lock.lock(); defer { lock.unlock() }
//        let obtainedMessage: Message
//
//        if let pool = pool.pointee {
//            let message = pool
//            self.pool.pointee = message.next.pointee
//            message.next.pointee = nil
//            message.inUse = false
//            poolSize -= 1
//            obtainedMessage = message
//        } else {
//            obtainedMessage = Message()
//        }
//
//        let pointer = UnsafeMutablePointer<Message>.allocate(capacity: 1)
//        pointer.initialize(to: obtainedMessage)
//        return pointer
//    }
//
//    static func recycle(_ pointer: UnsafeMutablePointer<Message>) {
//        if pointer.pointee.inUse {
//            assertionFailure()
//            return
//        }
//
//        recycleUnchecked(pointer)
//    }
//
//    static func recycleUnchecked(_ pointer: UnsafeMutablePointer<Message>) {
//        pointer.pointee.inUse = true
//        pointer.pointee.what = EmptyMessageKind()
//        pointer.pointee.target = nil
//        pointer.pointee.callback = nil
//
//        Self.lock.withLock {
//            if Self.poolSize < .maxPoolSize {
//                pointer.pointee.next = Self.pool
//                Self.pool.pointee = pointer.pointee
//                Self.poolSize += 1
//            }
//        }
//    }
//
//    func sendToTarget() {
//        target?.sendMessage(self)
//    }
//}
