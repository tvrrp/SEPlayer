//
//  MessageQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.11.2025.
//

import Foundation

//final class MessageQueue: @unchecked Sendable {
//
//    protocol IdleHandler: AnyObject {
//        nonisolated func queueIdle() -> Bool
//    }
//
//    private let lock = UnfairLock()
//    private let timerQueue = DispatchQueue(label: "com.seplayer.timer", qos: .userInitiated)
//
//    private var messages: UnsafeMutablePointer<Message>?
//    private var lastMessage: UnsafeMutablePointer<Message>?
//    private var idleHandlers = NSHashTable<AnyObject>()
//
//    private var quiting = false
//    private var blocked = false
//    private var awaitingContinuation: CheckedContinuation<Void, Error>?
//    private var awaitingTimerTask: Task<Void, Error>?
//
//    deinit {
//        awaitingContinuation?.resume(throwing: CancellationError())
//        awaitingContinuation = nil
//        awaitingTimerTask?.cancel()
//        awaitingTimerTask = nil
//    }
//
//    var isIdle: Bool {
//        lock.withLock {
//            let nowNs = DispatchTime.now().uptimeNanoseconds
//            if let msg = messages {
//                return nowNs < msg.pointee.whenNs
//            } else {
//                return false
//            }
//        }
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
//    func enqueueMessage(
//        _ message: UnsafeMutablePointer<Message>,
//        whenNs: UInt64
//    ) -> Bool {
//        precondition(message.pointee.target != nil)
//
//        lock.lock(); defer { lock.unlock() }
//        precondition(!message.pointee.inUse)
//
//        if quiting {
//            Message.recycle(message)
//            return false
//        }
//
//        message.pointee.inUse = true
//        message.pointee.whenNs = whenNs
//        message.pointee.next = nil
//
//        let head = messages
//        var needWake = false
//
//        switch head {
//        case .some(let p) where whenNs != 0 && whenNs >= p.pointee.whenNs:
//            var current: UnsafeMutablePointer<Message>? = p
//            var prev: UnsafeMutablePointer<Message>?
//
//            while let c = current {
//                if whenNs < c.pointee.whenNs { break }
//                prev = c
//                current = c.pointee.next
//            }
//
//            message.pointee.next = current
//            prev!.pointee.next = message
//
//            if message.pointee.next == nil {
//                lastMessage = message
//            }
//
//        default:
//            message.pointee.next = head
//            messages = message
//            if head == nil {
//                lastMessage = message
//            }
//            needWake = blocked
//        }
//
//        if needWake {
//            awaitingContinuation?.resume()
//            awaitingContinuation = nil
//            awaitingTimerTask?.cancel()
//            awaitingTimerTask = nil
//        }
//
//        return true
//    }
//
//    func hasMessages(handler: Handler, what: MessageKind) -> Bool {
//        lock.withLock {
//            var p = messages
//            while let previous = p {
//                if previous.pointee.target === handler, previous.pointee.what.isEqual(to: what) {
//                    return true
//                }
//                p = previous.pointee.next
//            }
//
//            return false
//        }
//    }
//
//    func removeMessages(handler: Handler, what: MessageKind) {
//        lock.withLock {
//            var p = messages
//
//            // Remove from head
//            while let cur = p,
//                  cur.pointee.target === handler,
//                  cur.pointee.what.isEqual(to: what) {
//
//                let next = cur.pointee.next
//                messages = next
//                cur.pointee.next = nil
//                cur.pointee.inUse = false
//                Message.recycle(cur)
//                p = next
//            }
//
//            if p == nil {
//                lastMessage = messages
//            }
//
//            // Remove in middle / tail
//            while let cur = p {
//                if let n = cur.pointee.next,
//                   n.pointee.target === handler,
//                   n.pointee.what.isEqual(to: what) {
//
//                    let nn = n.pointee.next
//                    cur.pointee.next = nn
//                    n.pointee.next = nil
//                    n.pointee.inUse = false
//                    Message.recycle(n)
//
//                    if nn == nil {
//                        lastMessage = cur
//                    }
//                } else {
//                    p = cur.pointee.next
//                }
//            }
//        }
//    }
//
//    func next() async throws -> UnsafeMutablePointer<Message>? {
//        var pendingIdleHandlerCount = -1
//        var nextPollTimeoutNs: Int64 = 0
//
//        while true {
//            try await poolOnce(timeoutNs: nextPollTimeoutNs)
//
//            lock.lock()
//
//            let now = DispatchTime.now().uptimeNanoseconds
//            let msg = messages
//
//            if let m = msg {
//                if now < m.pointee.whenNs {
//                    nextPollTimeoutNs = Int64(
//                        min(m.pointee.whenNs &- now, UInt64(UInt32.max))
//                    )
//                } else {
//                    blocked = false
//                    messages = m.pointee.next
//                    if messages == nil {
//                        lastMessage = nil
//                    }
//                    m.pointee.next = nil
//                    m.pointee.inUse = true
//                    lock.unlock()
//                    return m
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
//            let shouldRunIdle = messages.map {
//                now < $0.pointee.whenNs
//            } ?? true
//
//            if pendingIdleHandlerCount < 0, shouldRunIdle {
//                pendingIdleHandlerCount = idleHandlers.count
//            }
//
//            if pendingIdleHandlerCount <= 0 {
//                blocked = true
//                lock.unlock()
//                continue
//            }
//
//            let handlers = idleHandlers.allObjects as! [IdleHandler]
//            lock.unlock()
//
//            handlers.forEach { handler in
//                if !handler.queueIdle() {
//                    lock.withLock { idleHandlers.remove(handler) }
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
//            awaitingTimerTask?.cancel()
//            awaitingTimerTask = nil
//        }
//    }
//
//    private func removeAllMessagesLocked() {
//        while let m = messages {
//            let next = m.pointee.next
//            m.pointee.next = nil
//            m.pointee.inUse = false
//            Message.recycle(m)
//            messages = next
//        }
//        messages = nil
//        lastMessage = nil
//    }
//
//    private func removeAllFutureMessagesLocked() {
//        let now = DispatchTime.now().uptimeNanoseconds
//        guard var p = messages else { return }
//
//        if p.pointee.whenNs > now {
//            removeAllMessagesLocked()
//            return
//        }
//
//        while let n = p.pointee.next {
//            if n.pointee.whenNs > now { break }
//            p = n
//        }
//
//        var tail = p.pointee.next
//        p.pointee.next = nil
//        lastMessage = p
//
//        while let m = tail {
//            tail = m.pointee.next
//            m.pointee.next = nil
//            m.pointee.inUse = false
//            Message.recycle(m)
//        }
//    }
//
//    private func poolOnce(timeoutNs: Int64) async throws {
//        if timeoutNs < 0 {
//            return try await withCheckedThrowingContinuation { cont in
//                lock.withLock { awaitingContinuation = cont }
//            }
//        } else if timeoutNs == 0 {
//            return
//        } else {
//            let timerTask = Task {
//                let now = DispatchTime.now()
//                let deadline = now.advanced(by: .nanoseconds(Int(timeoutNs)))
//
//                do {
//                    if #available(iOS 16, *) {
//                        try await Task.sleep(
//                            for: .nanoseconds(deadline.uptimeNanoseconds - now.uptimeNanoseconds),
//                            tolerance: .nanoseconds(0),
//                            clock: .continuous
//                        )
//                    } else {
//                        try await Task.sleep(for: now.distance(to: deadline), queue: timerQueue)
//                    }
//                } catch {
//                    if error is CancellationError { return }
//                    throw error
//                }
//            }
//
//            lock.withLock { awaitingTimerTask = timerTask }
//            try await timerTask.value
//        }
//    }
//}

final class MessageQueue: @unchecked Sendable {

    protocol IdleHandler: AnyObject {
        nonisolated func queueIdle() -> Bool
    }

    private let lock = UnfairLock()
    private let timerQueue = DispatchQueue(label: "com.seplayer.timer", qos: .userInitiated)

    private var messages: Message?
    private var lastMessage: Message?
    private var idleHandlers = NSHashTable<AnyObject>()

    private var quiting = false
    private var blocked = false
    private var awaitingContinuation: CheckedContinuation<Void, Error>?
    private var awaitingTimerTask: Task<Void, Error>?

    deinit {
        awaitingContinuation?.resume(throwing: CancellationError())
        awaitingContinuation = nil
        awaitingTimerTask?.cancel()
        awaitingTimerTask = nil
    }

    var isIdle: Bool {
        lock.withLock {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if let msg = messages {
                return nowNs < msg.whenNs
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
        _ message: Message,
        whenNs: UInt64
    ) -> Bool {
        precondition(message.target != nil)

        lock.lock(); defer { lock.unlock() }
        precondition(!message.inUse)

        if quiting {
            message.recycle()
            return false
        }

        message.inUse = true
        message.whenNs = whenNs
        message.next = nil

        let head = messages
        var needWake = false

        switch head {
        case .some(let p) where whenNs != 0 && whenNs >= p.whenNs:
            var current: Message? = p
            var prev: Message?

            while let c = current {
                if whenNs < c.whenNs { break }
                prev = c
                current = c.next
            }

            message.next = current
            prev!.next = message

            if message.next == nil {
                lastMessage = message
            }

        default:
            message.next = head
            messages = message
            if head == nil {
                lastMessage = message
            }
            needWake = blocked
        }

        if needWake {
            awaitingContinuation?.resume()
            awaitingContinuation = nil
            awaitingTimerTask?.cancel()
            awaitingTimerTask = nil
        }

        return true
    }

    func hasMessages(handler: Handler, what: MessageKind) -> Bool {
        lock.withLock {
            var p = messages
            while let previous = p {
                if previous.target === handler, previous.what.isEqual(to: what) {
                    return true
                }
                p = previous.next
            }

            return false
        }
    }

    func removeMessages(handler: Handler, what: MessageKind) {
        lock.withLock {
            var p = messages

            // Remove from head
            while let cur = p,
                  cur.target === handler,
                  cur.what.isEqual(to: what) {

                let next = cur.next
                messages = next
                cur.next = nil
                cur.inUse = false
                cur.recycle()
                p = next
            }

            if p == nil {
                lastMessage = messages
            }

            // Remove in middle / tail
            while let cur = p {
                if let n = cur.next,
                   n.target === handler,
                   n.what.isEqual(to: what) {

                    let nn = n.next
                    cur.next = nn
                    n.next = nil
                    n.inUse = false
                    n.recycle()

                    if nn == nil {
                        lastMessage = cur
                    }
                } else {
                    p = cur.next
                }
            }
        }
    }

    func next() async throws -> Message? {
        var pendingIdleHandlerCount = -1
        var nextPollTimeoutNs: Int64 = 0

        while true {
            try await poolOnce(timeoutNs: nextPollTimeoutNs)

            lock.lock()

            let now = DispatchTime.now().uptimeNanoseconds
            let msg = messages

            if let m = msg {
                if now < m.whenNs {
                    nextPollTimeoutNs = Int64(
                        min(m.whenNs &- now, UInt64(UInt32.max))
                    )
                } else {
                    blocked = false
                    messages = m.next
                    if messages == nil {
                        lastMessage = nil
                    }
                    m.next = nil
                    m.inUse = true
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
                now < $0.whenNs
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
            awaitingTimerTask?.cancel()
            awaitingTimerTask = nil
        }
    }

    private func removeAllMessagesLocked() {
        while let m = messages {
            let next = m.next
            m.next = nil
            m.inUse = false
            m.recycle()
            messages = next
        }
        messages = nil
        lastMessage = nil
    }

    private func removeAllFutureMessagesLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard var p = messages else { return }

        if p.whenNs > now {
            removeAllMessagesLocked()
            return
        }

        while let n = p.next {
            if n.whenNs > now { break }
            p = n
        }

        var tail = p.next
        p.next = nil
        lastMessage = p

        while let m = tail {
            tail = m.next
            m.next = nil
            m.inUse = false
            m.recycle()
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
            let timerTask = Task {
                let now = DispatchTime.now()
                let deadline = now.advanced(by: .nanoseconds(Int(timeoutNs)))

                do {
                    if #available(iOS 16, *) {
                        try await Task.sleep(
                            for: .nanoseconds(deadline.uptimeNanoseconds - now.uptimeNanoseconds),
                            tolerance: .nanoseconds(0),
                            clock: .continuous
                        )
                    } else {
                        try await Task.sleep(for: now.distance(to: deadline), queue: timerQueue)
                    }
                } catch {
                    if error is CancellationError { return }
                    throw error
                }
            }

            lock.withLock { awaitingTimerTask = timerTask }
            try await timerTask.value
        }
    }
}
