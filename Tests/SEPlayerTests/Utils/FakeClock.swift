//
//  FakeClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 08.11.2025.
//

import CoreMedia
import Testing
@testable import SEPlayer

final class FakeClock: SEClock {
    let clock: CMClock = CMClockGetHostTimeClock()

    var milliseconds: Int64 {
        lock.withLock { bootTimeMs + timeSinceBootMs }
    }

    var microseconds: Int64 {
        Time.msToUs(timeMs: milliseconds)
    }

    var nanoseconds: Int64 {
        Time.msToUs(timeMs: milliseconds) * 1000
    }

    private static var messageIdProvider = 0
    private static let messageIdLock = UnfairLock()

    private let isAutoAdvancing: Bool
    private var handlerMessages: NSHashTable<ClockMessage>
    private var busyLoopers: NSHashTable<Looper>
    private var bootTimeMs: Int64
    private var timeSinceBootMs: Int64
    private var waitingForMessage: Bool
    private let lock: UnfairLock

    init(
        bootTimeMs: Int64 = 0,
        initialTimeMs: Int64 = 0,
        isAutoAdvancing: Bool = true
    ) {
        self.bootTimeMs = bootTimeMs
        self.timeSinceBootMs = initialTimeMs
        self.isAutoAdvancing = isAutoAdvancing
        handlerMessages = NSHashTable<ClockMessage>()
        busyLoopers = NSHashTable<Looper>()
        waitingForMessage = false
        lock = UnfairLock()
    }

    func advanceTime(_ timeDiffMs: Int64) {
        advanceTimeInternal(timeDiffMs: timeDiffMs)
        maybeTriggerMessage()
    }

    func createHandler(queue: Queue, looper: Looper?) -> HandlerWrapper {
        ClockHandler(
            queue: queue,
            looper: looper,
            pendingHandlerMessageClosure: { [weak self] message in
                guard let self else { return }
                addPendingHandlerMessage(message)
            },
            removePendingHandlerMessagesClosure: { [weak self] hander, what in
                guard let self else { return }
                removePendingHandlerMessages(handler: hander, what: what)
            },
            uptimeMsGetter: { [weak self] in
                guard let self else { return .zero }
                return timeSinceBootMs
            }
        )
    }

    private func addPendingHandlerMessage(_ message: ClockMessage) {
        lock.withLock {
            handlerMessages.add(message)
            if !waitingForMessage {
                waitingForMessage = true

                DispatchQueue.main.async { [weak self] in
                    self?.onMessageHandled()
                }
            }
        }
    }

    private func removePendingHandlerMessages(handler: ClockHandler, what: MessageKind) {
        lock.withLock {
            for message in handlerMessages.allObjects.reversed() {
                if message.handler === handler, message.what.isEqual(to: what) {
                    handlerMessages.remove(message)
                }
            }

            handler.handler.removeMessages(what)
        }
    }

    private func hasPendingMessage(handler: ClockHandler, what: MessageKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for message in handlerMessages.allObjects {
            if message.target === handler, message.what.isEqual(to: what) {
                return true
            }
        }

//            TODO: return handler.handler.h
        return false
    }

    private func maybeTriggerMessage() {
        lock.lock()
        guard !waitingForMessage else {
            lock.unlock()
            return
        }
        guard handlerMessages.count > 0 else {
            lock.unlock()
            return
        }

        let objects = handlerMessages.allObjects.sorted()
        let message = objects[0]

        if message.timeMs > timeSinceBootMs {
            if isAutoAdvancing {
                lock.unlock()
                advanceTimeInternal(timeDiffMs: Int64(message.timeMs) - timeSinceBootMs)
                lock.lock()
            } else {
                return
            }
        }

        handlerMessages.remove(message)
        waitingForMessage = true
        lock.unlock()
        var messageSent = false
        let realHandler = message.handler.handler
        if let callback = message.callback {
            messageSent = realHandler.post(callback)
        } else {
            messageSent = realHandler.sendMessage(realHandler.obtainMessage(what: message.what))
        }
        messageSent = messageSent && message.handler.internalHandler.post { [weak self] in
            self?.onMessageHandled()
        }

        if !messageSent {
            onMessageHandled()
        }
    }

    private func onMessageHandled() {
        lock.withLock {
            waitingForMessage = false
        }
        maybeTriggerMessage()
    }

    func advanceTimeInternal(timeDiffMs: Int64) {
        lock.withLock { timeSinceBootMs += timeDiffMs }
    }

    static func nextMessageId() -> Int {
        messageIdLock.withLock {
            let messageIdProvider = Self.messageIdProvider
            Self.messageIdProvider += 1
            return messageIdProvider
        }
    }
}

private final class ClockMessage: HandlerWrapperMessage, Hashable, Comparable {
    var target: HandlerWrapper? { handler }

    let messageId: Int
    let handler: ClockHandler
    let callback: (() -> Void)?
    let timeMs: Int64
    let what: MessageKind
    let pendingHandlerMessageClosure: (ClockMessage) -> Void

    init(
        timeMs: Int64,
        handler: ClockHandler,
        what: MessageKind,
        pendingHandlerMessageClosure: @escaping (ClockMessage) -> Void,
        callback: (() -> Void)? = nil
    ) {
        self.messageId = FakeClock.nextMessageId()
        self.timeMs = timeMs
        self.handler = handler
        self.what = what
        self.pendingHandlerMessageClosure = pendingHandlerMessageClosure
        self.callback = callback
    }

    func sendToTarget() {
        pendingHandlerMessageClosure(self)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    static func == (lhs: ClockMessage, rhs: ClockMessage) -> Bool {
        return lhs === rhs
    }

    static func < (lhs: ClockMessage, rhs: ClockMessage) -> Bool {
        if lhs.timeMs != rhs.timeMs {
            return lhs.timeMs < rhs.timeMs
        }

        if lhs.timeMs == .min {
            return lhs.messageId > rhs.messageId
        } else {
            return lhs.messageId < rhs.messageId
        }
    }
}

private final class ClockHandler: HandlerWrapper {
    var callback: Handler.Callback? {
        get { handler.callback }
        set { handler.callback = newValue }
    }

    var looper: Looper { handler.looper }

    let handler: Handler
    let internalHandler: Handler

    private let pendingHandlerMessageClosure: (ClockMessage) -> Void
    private let removePendingHandlerMessagesClosure: (ClockHandler, MessageKind) -> Void
    private let uptimeMsGetter: (() -> Int64)

    init(
        queue: Queue,
        looper: Looper?,
        pendingHandlerMessageClosure: @escaping (ClockMessage) -> Void,
        removePendingHandlerMessagesClosure: @escaping (ClockHandler, MessageKind) -> Void,
        uptimeMsGetter: @escaping (() -> Int64)
    ) {
        handler = Handler(queue: queue, looper: looper)
        internalHandler = Handler(queue: queue, looper: looper)
        self.pendingHandlerMessageClosure = pendingHandlerMessageClosure
        self.removePendingHandlerMessagesClosure = removePendingHandlerMessagesClosure
        self.uptimeMsGetter = uptimeMsGetter
    }

    func hasMessage(_ what: MessageKind) -> Bool {
        return false // TODO: fixme
    }

    func obtainMessage(what: MessageKind) -> HandlerWrapperMessage {
        ClockMessage(
            timeMs: uptimeMsGetter(),
            handler: self,
            what: what,
            pendingHandlerMessageClosure: pendingHandlerMessageClosure
        )
    }

    func sendMessageAtFrontOfQueue(_ msg: HandlerWrapperMessage) -> Bool {
        guard let message = msg as? ClockMessage else {
            return false
        }

        ClockMessage(
            timeMs: .min,
            handler: self,
            what: message.what,
            pendingHandlerMessageClosure: message.pendingHandlerMessageClosure
        ).sendToTarget()

        return true
    }

    func sendEmptyMessage(_ what: MessageKind) -> Bool {
        sendEmptyMessageAtTime(
            what,
            timeNs: .init(uptimeNanoseconds: UInt64(uptimeMsGetter() * 1000))
        )
    }

    func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool {
        sendEmptyMessageAtTime(
            what,
            timeNs: .init(uptimeNanoseconds: UInt64((Int(uptimeMsGetter()) + delayMs)  * 1000))
        )
    }

    func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool {
        ClockMessage(
            timeMs: Int64(timeNs.uptimeNanoseconds / 1000),
            handler: self,
            what: what,
            pendingHandlerMessageClosure: pendingHandlerMessageClosure
        ).sendToTarget()
        return true
    }

    func removeMessages(_ what: MessageKind) {
        removePendingHandlerMessagesClosure(self, what)
    }

    func post(_ callback: @escaping () -> Void) {
        ClockMessage(
            timeMs: Int64(DispatchTime.now().uptimeNanoseconds),
            handler: self,
            what: EmptyMessageKind(),
            pendingHandlerMessageClosure: pendingHandlerMessageClosure,
            callback: callback
        ).sendToTarget()
    }
}
