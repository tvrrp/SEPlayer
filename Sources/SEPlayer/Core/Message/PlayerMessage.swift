//
//  PlayerMessage.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 26.12.2025.
//

public final class PlayerMessage {
    public protocol Sender: AnyObject {
        func sendMessage(_ message: PlayerMessage)
    }

    public let target: ((_ messageType: Int, _ message: Any?) async -> Void)
    private weak var sender: Sender?
    private let clock: SEClock
    public let timeline: Timeline

    public private(set) var type = 0
    public private(set) var payload: Any?
    public private(set) var queue: Queue
    public private(set) var mediaItemIndex: Int
    public private(set) var positionMs = Int64.zero
    public private(set) var deleteAfterDelivery = false
    private var isSent = false
    @UnfairLocked private var isDelivered = false
    @UnfairLocked private var isProcessed = false
    @UnfairLocked public private(set) var isCanceled = false

    @UnfairLocked private var continuations = [CheckedContinuation<Void, Never>]()

    init(
        sender: Sender,
        target: @escaping (_ messageType: Int, _ message: Any?) async -> Void,
        timeline: Timeline,
        defaultMediaItemIndex: Int,
        clock: SEClock,
        defaultQueue: Queue,
    ) {
        self.sender = sender
        self.target = target
        self.timeline = timeline
        self.queue = defaultQueue
        self.clock = clock
        self.mediaItemIndex = defaultMediaItemIndex
        self.positionMs = .timeUnset
        self.deleteAfterDelivery = true
    }

    @discardableResult
    public func setType(_ messageType: Int) -> PlayerMessage {
        assert(!isSent)
        type = messageType
        return self
    }

    @discardableResult
    public func setPayload(_ payload: Any?) -> PlayerMessage {
        assert(!isSent)
        self.payload = payload
        return self
    }

    @discardableResult
    public func setQueue(_ queue: Queue) -> PlayerMessage {
        assert(!isSent)
        self.queue = queue
        return self
    }

    @discardableResult
    public func setPositionMs(_ positionMs: Int64) -> PlayerMessage {
        assert(!isSent)
        self.positionMs = positionMs
        return self
    }

    @discardableResult
    public func setPositionMs(_ positionMs: Int64, mediaItemIndex: Int) -> PlayerMessage {
        assert(!isSent)
        assert(positionMs != .timeUnset)
        if mediaItemIndex < 0 || (!timeline.isEmpty && mediaItemIndex >= timeline.windowCount()) {
            assertionFailure()
        }
        self.mediaItemIndex = mediaItemIndex
        self.positionMs = positionMs
        return self
    }

    @discardableResult
    public func setDeleteAfterDelivery(_ deleteAfterDelivery: Bool) -> PlayerMessage {
        assert(!isSent)
        self.deleteAfterDelivery = deleteAfterDelivery
        return self
    }

    @discardableResult
    public func send() -> PlayerMessage {
        assert(!isSent)
        if positionMs == .timeUnset {
            assert(deleteAfterDelivery)
        }
        isSent = true
        sender?.sendMessage(self)
        return self
    }

    @discardableResult
    public func cancel() -> PlayerMessage {
        assert(isSent)
        isCanceled = true
        markAsProcessed(isDelivered: false)
        return self
    }

    public func markAsProcessed(isDelivered: Bool) {
        self.isDelivered = self.isDelivered || isDelivered
        isProcessed = true
        continuations.forEach { $0.resume() }
        continuations.removeAll(keepingCapacity: true)
    }

    public func waitUntilDelivered() async throws -> Bool {
        assert(isSent)
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }

        return isDelivered
    }
}
