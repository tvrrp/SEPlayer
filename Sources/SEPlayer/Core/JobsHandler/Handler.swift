//
//  Handler.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.11.2025.
//

import Dispatch

public class Handler {
    public protocol Callback: AnyObject {
        func handleMessage(msg: UnsafeMutablePointer<Message>) -> Bool
    }

    public weak var callback: Callback?
    public let looper: Looper

    private let queue: Queue
    private let messageQueue: MessageQueue

    public init(queue: Queue, looper: Looper? = nil) {
        self.queue = queue
        if let looper {
            self.looper = looper
        } else {
            let looper = Looper.myLooper(for: queue)
            self.looper = looper
        }
        self.messageQueue = self.looper.messageQueue
    }

    public func dispatchMessage(msg: UnsafeMutablePointer<Message>) {
        assert(queue.isCurrent())
        if let callback = msg.pointee.callback {
            callback()
        } else {
            _ = callback?.handleMessage(msg: msg)
        }
    }

    public func obtainMessage(what: MessageKind? = nil) -> UnsafeMutablePointer<Message> {
        Message.obtain(handler: self, what: what)
    }

    @discardableResult
    public func sendMessage(_ msg: UnsafeMutablePointer<Message>) -> Bool {
        sendMessageDelayed(msg, delayMs: 0)
    }

    @discardableResult
    public func sendEmptyMessage(_ what: MessageKind) -> Bool {
        sendEmptyMessageDelayed(what, delayMs: 0)
    }

    @discardableResult
    public func sendEmptyMessageDelayed(_ what: MessageKind, delayMs: Int) -> Bool {
        let msg = Message.obtain()
        msg.pointee.what = what
        return sendMessageDelayed(msg, delayMs: delayMs)
    }

    @discardableResult
    public func sendEmptyMessageAtTime(_ what: MessageKind, timeNs: DispatchTime) -> Bool {
        let msg = Message.obtain()
        msg.pointee.what = what
        return sendMessageAtTime(msg, timeNs: timeNs)
    }

    @discardableResult
    func post(_ callback: @escaping () -> Void) -> Bool {
        sendMessageDelayed(getPostMessage(callback), delayMs: 0)
    }

    @discardableResult
    public func sendMessageDelayed(_ msg: UnsafeMutablePointer<Message>, delayMs: Int) -> Bool {
        sendMessageAtTime(msg, timeNs: DispatchTime.now().advanced(by: .milliseconds(delayMs)))
    }

    @discardableResult
    public func sendMessageAtTime(_ msg: UnsafeMutablePointer<Message>, timeNs: DispatchTime) -> Bool {
        enqueueMessage(queue: messageQueue, msg: msg, uptimeNs: timeNs.uptimeNanoseconds)
    }

    @discardableResult
    public func sendMessageAtFrontOfQueue(_ msg: UnsafeMutablePointer<Message>) -> Bool {
        enqueueMessage(queue: messageQueue, msg: msg, uptimeNs: 0)
    }

    @discardableResult
    public func executeOrSendMessage(_ msg: UnsafeMutablePointer<Message>) -> Bool {
        if queue.isCurrent() {
            dispatchMessage(msg: msg)
            return true
        }

        return sendMessage(msg)
    }

    public func removeMessages(_ what: MessageKind) {
        messageQueue.removeMessages(handler: self, what: what)
    }

    @discardableResult
    private func enqueueMessage(queue: MessageQueue, msg: UnsafeMutablePointer<Message>, uptimeNs: UInt64) -> Bool {
        msg.pointee.target = self

        return queue.enqueueMessage(msg, whenNs: uptimeNs)
    }

    private func getPostMessage(_ callback: @escaping () -> Void) -> UnsafeMutablePointer<Message> {
        let message = Message.obtain()
        message.pointee.callback = callback
        message.pointee.what = PostMessageKind()
        return message
    }

//    public func hasMessage(_ what: MessageKind) {
//        messageQueue.
//    }
}

struct PostMessageKind: MessageKind {
    func isEqual(to other: any MessageKind) -> Bool {
        if other is PostMessageKind {
            return true
        }

        return false
    }
}
