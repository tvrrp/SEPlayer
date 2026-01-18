//
//  MessageQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.11.2025.
//

import Foundation

//final class MessageQueue: @unchecked Sendable {
//    protocol IdleHandler: AnyObject {
//        nonisolated func queueIdle() -> Bool
//    }
//
//    var isIdle: Bool {
//        lock.withLock {
//            let nowNs = DispatchTime.now().uptimeNanoseconds
//            if let messages {
//                return nowNs < messages.whenNs
//            } else {
//                return false
//            }
//        }
//    }
//
//    private let lock = UnfairLock()
//
//    private var messages: Message?
//    private var lastMessage: Message?
//    private var idleHandlers = NSHashTable<AnyObject>()
//
//    private var quiting = false
//    private var blocked = false
//    private var awaitingContinuation: CheckedContinuation<Void, Error>?
//
//    deinit {
//        awaitingContinuation?.resume(throwing: CancellationError())
//        awaitingContinuation = nil
//    }
//
//    func addIdleHandler(_ handler: IdleHandler) {
//        lock.withLock { idleHandlers.add(handler) }
//    }
//
//    func removeIdleHandler(_ handler: IdleHandler) {
//        lock.withLock { idleHandlers.remove(handler) }
//    }
//
//    func enqueueMessage(_ message: Message, whenNs: UInt64) -> Bool {
//        precondition(message.target != nil)
//        lock.lock(); defer { lock.unlock() }
//        precondition(!message.inUse)
//
//        if quiting {
//            message.recycle()
//            return false
//        }
//
//        message.inUse = true
//        message.whenNs = whenNs
//        let previous = messages
//        var needWake = false
//
//        switch previous {
//        case let .some(p):
//            if whenNs == 0 || whenNs < p.whenNs { fallthrough }
//
//            var p: Message? = p
//            var prev: Message?
//            while true {
//                prev = p
//                p = p?.next
//                guard let p else { break }
//                if whenNs < p.whenNs { break }
//            }
//            message.next = p
//            prev?.next = message
//        case .none:
//            message.next = previous
//            messages = message
//            needWake = blocked
//            if previous == nil {
//                lastMessage = messages
//            }
//
//            lastMessage = nil
//        }
//
//        if needWake {
//            awaitingContinuation?.resume()
//            awaitingContinuation = nil
//        }
//        return true
//    }
//
//    func removeMessages(handler: Handler, what: MessageKind) {
//        lock.withLock {
//            var p = messages
//
//            // Remove all messages at front.
//            while let previous = p,
//                  previous.target === handler,
//                  previous.what.isEqual(to: what) {
//                let n = previous.next
//                messages = n
//                previous.recycleUnchecked()
//                p = n
//            }
//
//            if p == nil {
//                lastMessage = messages
//            }
//
//            while let previous = p {
//                let n = previous.next
//                if let n {
//                    if n.target === handler, n.what.isEqual(to: what) {
//                        let nn = n.next
//                        n.recycleUnchecked()
//                        previous.next = nn
//                        if previous.next == nil {
//                            lastMessage = p
//                        }
//                        continue
//                    }
//                }
//                p = n
//            }
//        }
//    }
//
//    func next() async throws -> Message? {
//        var pendingIdleHandlerCount = -1
//        var nextPollTimeoutNs: Int64 = 0
//
//        while true {
//            try await poolOnce(timeoutNs: nextPollTimeoutNs)
//
//            lock.lock()
//            let now = DispatchTime.now().uptimeNanoseconds
//            let prevMsg: Message? = nil
//            let msg = messages
//            if let msg {
//                if now < msg.whenNs {
//                    nextPollTimeoutNs = Int64(min(msg.whenNs &- now, UInt64(UInt32.max)))
//                } else {
//                    blocked = false
//                    if let prevMsg {
//                        prevMsg.next = msg.next
//                        if prevMsg.next == nil {
//                            lastMessage = prevMsg
//                        }
//                    } else {
//                        messages = msg.next
//                        if msg.next == nil {
//                            lastMessage = nil
//                        }
//                    }
//                    msg.next = nil
//                    msg.inUse = true
//                    lock.unlock()
//                    return msg
//                }
//            } else {
//                nextPollTimeoutNs = -1
//            }
//
//            if quiting {
//                lock.unlock()
//                return nil
//            }
//
//            let shouldRun = if let messages {
//                now < messages.whenNs
//            } else {
//                true
//            }
//
//            if pendingIdleHandlerCount < 0, shouldRun {
//                pendingIdleHandlerCount = idleHandlers.count
//            }
//
//            if pendingIdleHandlerCount <= 0 {
//                blocked = true
//                lock.unlock()
//                continue
//            }
//
//            let pendingIdleHandlers = idleHandlers.allObjects as! [IdleHandler]
//            lock.unlock()
//
//            pendingIdleHandlers.forEach { idler in
//                if idler.queueIdle() == false {
//                    lock.withLock { idleHandlers.remove(idler) }
//                }
//            }
//
//            pendingIdleHandlerCount = 0
//            nextPollTimeoutNs = 0
//        }
//    }
//
//    func quit(safe: Bool) {
//        lock.withLock {
//            guard !quiting else { return }
//            quiting = true
//
//            if safe {
//                removeAllFutureMessagesLocked()
//            } else {
//                removeAllMessagesLocked()
//            }
//
//            awaitingContinuation?.resume()
//            awaitingContinuation = nil
//        }
//    }
//
//    private func removeAllMessagesLocked() {
//        while let message = messages {
//            let next = message.next
//            message.recycleUnchecked()
//            self.messages = next
//        }
//
//        messages = nil
//        lastMessage = nil
//    }
//
//    private func removeAllFutureMessagesLocked() {
//        let now = DispatchTime.now().uptimeNanoseconds
//        if var p = messages {
//            if p.whenNs > now {
//                removeAllMessagesLocked()
//            } else {
//                var n: Message?
//                while true {
//                    n = p.next
//                    guard let n else { return }
//                    if n.whenNs > now { break }
//                    p = n
//                }
//
//                p.next = nil
//                lastMessage = p
//
//                while let next = n {
//                    p = next
//                    n = p.next
//                    p.recycleUnchecked()
//                }
//            }
//        }
//    }
//
//    private func poolOnce(timeoutNs: Int64) async throws {
//        if timeoutNs < 0 {
//            return try await withCheckedThrowingContinuation { continuation in
//                self.lock.withLock { self.awaitingContinuation = continuation }
//            }
//        } else if timeoutNs == 0 {
//            return
//        } else {
//            let currentTime = DispatchTime.now()
//            let deadline = currentTime.advanced(by: .nanoseconds(Int(timeoutNs)))
//            try await Task.sleep(nanoseconds: deadline.uptimeNanoseconds - currentTime.uptimeNanoseconds)
//        }
//    }
//}

final class MessageQueue: @unchecked Sendable {

    protocol IdleHandler: AnyObject {
        nonisolated func queueIdle() -> Bool
    }

    private let lock = UnfairLock()

    private var messages: UnsafeMutablePointer<Message>?
    private var lastMessage: UnsafeMutablePointer<Message>?
    private var idleHandlers = NSHashTable<AnyObject>()

    private var quiting = false
    private var blocked = false
    private var awaitingContinuation: CheckedContinuation<Void, Error>?

    deinit {
        awaitingContinuation?.resume(throwing: CancellationError())
        awaitingContinuation = nil
    }

    var isIdle: Bool {
        lock.withLock {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if let msg = messages {
                return nowNs < msg.pointee.whenNs
            } else {
                return false
            }
        }
    }

    func addIdleHandler(_ handler: IdleHandler) {
        lock.withLock { idleHandlers.add(handler) }
    }

    func removeIdleHandler(_ handler: IdleHandler) {
        lock.withLock { idleHandlers.remove(handler) }
    }

    func enqueueMessage(
        _ message: UnsafeMutablePointer<Message>,
        whenNs: UInt64
    ) -> Bool {
        precondition(message.pointee.target != nil)

        lock.lock(); defer { lock.unlock() }
        precondition(!message.pointee.inUse)

        if quiting {
            Message.recycle(message)
            return false
        }

        message.pointee.inUse = true
        message.pointee.whenNs = whenNs
        message.pointee.next = nil

        let head = messages
        var needWake = false

        switch head {
        case .some(let p) where whenNs != 0 && whenNs >= p.pointee.whenNs:
            var current: UnsafeMutablePointer<Message>? = p
            var prev: UnsafeMutablePointer<Message>?

            while let c = current {
                if whenNs < c.pointee.whenNs { break }
                prev = c
                current = c.pointee.next
            }

            message.pointee.next = current
            prev!.pointee.next = message

            if message.pointee.next == nil {
                lastMessage = message
            }

        default:
            message.pointee.next = head
            messages = message
            if head == nil {
                lastMessage = message
            }
            needWake = blocked
        }

        if needWake {
            awaitingContinuation?.resume()
            awaitingContinuation = nil
        }

        return true
    }

    func removeMessages(handler: Handler, what: MessageKind) {
        lock.withLock {
            var p = messages

            // Remove from head
            while let cur = p,
                  cur.pointee.target === handler,
                  cur.pointee.what.isEqual(to: what) {

                let next = cur.pointee.next
                messages = next
                cur.pointee.next = nil
                cur.pointee.inUse = false
                Message.recycle(cur)
                p = next
            }

            if p == nil {
                lastMessage = messages
            }

            // Remove in middle / tail
            while let cur = p {
                if let n = cur.pointee.next,
                   n.pointee.target === handler,
                   n.pointee.what.isEqual(to: what) {

                    let nn = n.pointee.next
                    cur.pointee.next = nn
                    n.pointee.next = nil
                    n.pointee.inUse = false
                    Message.recycle(n)

                    if nn == nil {
                        lastMessage = cur
                    }
                } else {
                    p = cur.pointee.next
                }
            }
        }
    }

    func next() async throws -> UnsafeMutablePointer<Message>? {
        var pendingIdleHandlerCount = -1
        var nextPollTimeoutNs: Int64 = 0

        while true {
            try await poolOnce(timeoutNs: nextPollTimeoutNs)

            lock.lock()

            let now = DispatchTime.now().uptimeNanoseconds
            let msg = messages

            if let m = msg {
                if now < m.pointee.whenNs {
                    nextPollTimeoutNs = Int64(
                        min(m.pointee.whenNs &- now, UInt64(UInt32.max))
                    )
                } else {
                    blocked = false
                    messages = m.pointee.next
                    if messages == nil {
                        lastMessage = nil
                    }
                    m.pointee.next = nil
                    m.pointee.inUse = true
                    lock.unlock()
                    return m
                }
            } else {
                nextPollTimeoutNs = -1
            }

            if quiting {
                lock.unlock()
                return nil
            }

            let shouldRunIdle = messages.map {
                now < $0.pointee.whenNs
            } ?? true

            if pendingIdleHandlerCount < 0, shouldRunIdle {
                pendingIdleHandlerCount = idleHandlers.count
            }

            if pendingIdleHandlerCount <= 0 {
                blocked = true
                lock.unlock()
                continue
            }

            let handlers = idleHandlers.allObjects as! [IdleHandler]
            lock.unlock()

            handlers.forEach { handler in
                if !handler.queueIdle() {
                    lock.withLock { idleHandlers.remove(handler) }
                }
            }

            pendingIdleHandlerCount = 0
            nextPollTimeoutNs = 0
        }
    }

    func quit(safe: Bool) {
        lock.withLock {
            guard !quiting else { return }
            quiting = true

            if safe {
                removeAllFutureMessagesLocked()
            } else {
                removeAllMessagesLocked()
            }

            awaitingContinuation?.resume()
            awaitingContinuation = nil
        }
    }

    private func removeAllMessagesLocked() {
        while let m = messages {
            let next = m.pointee.next
            m.pointee.next = nil
            m.pointee.inUse = false
            Message.recycle(m)
            messages = next
        }
        messages = nil
        lastMessage = nil
    }

    private func removeAllFutureMessagesLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard var p = messages else { return }

        if p.pointee.whenNs > now {
            removeAllMessagesLocked()
            return
        }

        while let n = p.pointee.next {
            if n.pointee.whenNs > now { break }
            p = n
        }

        var tail = p.pointee.next
        p.pointee.next = nil
        lastMessage = p

        while let m = tail {
            tail = m.pointee.next
            m.pointee.next = nil
            m.pointee.inUse = false
            Message.recycle(m)
        }
    }

    private func poolOnce(timeoutNs: Int64) async throws {
        if timeoutNs < 0 {
            return try await withCheckedThrowingContinuation { cont in
                lock.withLock { awaitingContinuation = cont }
            }
        } else if timeoutNs == 0 {
            return
        } else {
            let now = DispatchTime.now()
            let deadline = now.advanced(by: .nanoseconds(Int(timeoutNs)))
            try await Task.sleep(
                nanoseconds: deadline.uptimeNanoseconds - now.uptimeNanoseconds
            )
        }
    }
}
