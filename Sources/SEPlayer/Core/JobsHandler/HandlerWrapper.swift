//
//  HandlerWrapper.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.11.2025.
//

import Dispatch

public protocol HandlerWrapperMessage: AnyObject {
    var target: HandlerWrapper? { get }
    func sendToTarget()
}

//public protocol HandlerWrapper: AnyObject {
//    var looper: Looper { get }
//    var callback: Handler.Callback? { get set }
////    TODO: func hasMessage(_ what: HandlerMessageKind)
//    func obtainMessage(what: MessageKind) -> UnsafeMutablePointer<HandlerWrapperMessage>
//    @discardableResult
//    func sendMessageAtFrontOfQueue(_ msg: UnsafeMutablePointer<HandlerWrapperMessage>) -> Bool
//    @discardableResult
//    func sendEmptyMessage(_ what: MessageKind) -> Bool
//    @discardableResult
//    func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool
//    @discardableResult
//    func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool
//    func removeMessages(_ what: MessageKind)
//    func post(_ callback: @escaping () -> Void)
//}

//final class DefaultHandlerWrapper: HandlerWrapper {
//    var looper: Looper { handler.looper }
//    var callback: Handler.Callback? {
//        get { handler.callback }
//        set { handler.callback = newValue }
//    }
//
//    private let handler: Handler
//
//    private static let poolSize = 50
//    private static let lock = UnfairLock()
//    private static var messagePool: [HandlerMessage] = {
//        var pool = [HandlerMessage]()
//        pool.reserveCapacity(poolSize)
//        return pool
//    }()
//
//    init(handler: Handler) {
//        self.handler = handler
//    }
//
//    func obtainMessage(what: MessageKind) -> UnsafeMutablePointer<HandlerWrapperMessage> {
//        let message = Self.obtainMessage()
//        (message.pointee as? HandlerMessage)?.setMessage(handler.obtainMessage(what: what), handler: self)
//        return message
//    }
//
//    func sendMessageAtFrontOfQueue(_ msg: UnsafeMutablePointer<HandlerWrapperMessage>) -> Bool {
//        (msg.pointee as? HandlerMessage)?.sendAtFrontOfQueue(handler: handler) ?? false
//    }
//
//    func sendEmptyMessage(_ what: MessageKind) -> Bool {
//        handler.sendEmptyMessage(what)
//    }
//
//    func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool {
//        handler.sendEmptyMessageDelayed(what, delayMs: delayMs)
//    }
//
//    func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool {
//        handler.sendEmptyMessageAtTime(what, timeNs: timeNs)
//    }
//
//    func removeMessages(_ what: MessageKind) {
//        handler.removeMessages(what)
//    }
//
//    func post(_ callback: @escaping () -> Void) {
//        handler.post(callback)
//    }
//
//    fileprivate static func obtainMessage() -> UnsafeMutablePointer<HandlerWrapperMessage> {
////        lock.withLock {
////            messagePool.isEmpty ? HandlerMessage() : messagePool.removeLast()
////        }
//        let message = UnsafeMutablePointer<HandlerWrapperMessage>.allocate(capacity: 1)
//        message.initialize(to: HandlerMessage())
//        return message
//    }
//
//    fileprivate static func recycleMessage(_ message: UnsafeMutablePointer<HandlerMessage>) {
//        message.deinitialize(count: 1)
//        message.deallocate()
////        lock.withLock {
////            if messagePool.count < poolSize {
////                messagePool.append(message)
////            }
////        }
//    }
//}
//
//private final class HandlerMessage: HandlerWrapperMessage {
//    var target: HandlerWrapper?
//    private var message: UnsafeMutablePointer<Message>?
//
//    @discardableResult
//    func setMessage(_ message: UnsafeMutablePointer<Message>, handler: DefaultHandlerWrapper) -> HandlerMessage {
//        self.message = message
//        target = handler
//        return self
//    }
//
//    func sendAtFrontOfQueue(handler: Handler) -> Bool {
//        guard let message else { return false }
//        let success = handler.sendMessageAtFrontOfQueue(message)
//        recycle()
//        return success
//    }
//
//    func sendToTarget() {
//        if let message {
//            Message.sendToTarget(message)
//        }
//
//        recycle()
//    }
//
//    private func recycle() {
//        message = nil
//        target = nil
////        DefaultHandlerWrapper.recycleMessage(self)
//    }
//}

public protocol HandlerWrapper: AnyObject {
    var looper: Looper { get }
    var callback: Handler.Callback? { get set }
    func hasMessage(_ what: MessageKind) -> Bool
    func obtainMessage(what: MessageKind) -> HandlerWrapperMessage
    @discardableResult
    func sendMessageAtFrontOfQueue(_ msg: HandlerWrapperMessage) -> Bool
    @discardableResult
    func sendEmptyMessage(_ what: MessageKind) -> Bool
    @discardableResult
    func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool
    @discardableResult
    func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool
    func removeMessages(_ what: MessageKind)
    func post(_ callback: @escaping () -> Void)
}

final class DefaultHandlerWrapper: HandlerWrapper {
    var looper: Looper { handler.looper }
    var callback: Handler.Callback? {
        get { handler.callback }
        set { handler.callback = newValue }
    }

    private let handler: Handler

    private static let poolSize = 50
    private static let lock = UnfairLock()
    private static var messagePool: [HandlerMessage] = {
        var pool = [HandlerMessage]()
        pool.reserveCapacity(poolSize)
        return pool
    }()

    init(handler: Handler) {
        self.handler = handler
    }

    func hasMessage(_ what: MessageKind) -> Bool {
        handler.hasMessage(what)
    }

    func obtainMessage(what: MessageKind) -> HandlerWrapperMessage {
        Self.obtainMessage().setMessage(handler.obtainMessage(what: what), handler: self)
    }

    func sendMessageAtFrontOfQueue(_ msg: HandlerWrapperMessage) -> Bool {
        (msg as? HandlerMessage)?.sendAtFrontOfQueue(handler: handler) ?? false
    }

    func sendEmptyMessage(_ what: MessageKind) -> Bool {
        handler.sendEmptyMessage(what)
    }

    func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool {
        handler.sendEmptyMessageDelayed(what, delayMs: delayMs)
    }

    func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool {
        handler.sendEmptyMessageAtTime(what, timeNs: timeNs)
    }

    func removeMessages(_ what: MessageKind) {
        handler.removeMessages(what)
    }

    func post(_ callback: @escaping () -> Void) {
        handler.post(callback)
    }

    fileprivate static func obtainMessage() -> HandlerMessage {
        lock.withLock {
            messagePool.isEmpty ? HandlerMessage() : messagePool.removeLast()
        }
    }

    fileprivate static func recycleMessage(_ message: HandlerMessage) {
        lock.withLock {
            if messagePool.count < poolSize {
                messagePool.append(message)
            }
        }
    }
}

private final class HandlerMessage: HandlerWrapperMessage {
    var target: HandlerWrapper?
    private var message: Message?

    @discardableResult
    func setMessage(_ message: Message, handler: DefaultHandlerWrapper) -> HandlerMessage {
        self.message = message
        target = handler
        return self
    }

    func sendAtFrontOfQueue(handler: Handler) -> Bool {
        guard let message else { return false }
        let success = handler.sendMessageAtFrontOfQueue(message)
        recycle()
        return success
    }

    func sendToTarget() {
        message?.sendToTarget()

        recycle()
    }

    private func recycle() {
        message = nil
        target = nil
        DefaultHandlerWrapper.recycleMessage(self)
    }
}
