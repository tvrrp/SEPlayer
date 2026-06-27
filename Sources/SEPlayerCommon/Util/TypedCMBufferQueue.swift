//
//  TypedCMBufferQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public final class TypedCMBufferQueue<T: CMBuffer>: @unchecked Sendable {
    /// Accesses buffers in a `CMBufferQueue`.
    public var buffers: CMBufferQueue.Buffers { bufferQueue.buffers }

    /// Returns whether or not the `CMBufferQueue` is empty.
    public var isEmpty: Bool { bufferQueue.isEmpty }

    /// Gets the number of buffers in the queue.
    public var bufferCount: CMItemCount { bufferQueue.bufferCount }

    /// Returns whether or not the `CMBufferQueue` is full.
    public var isFull: Bool { bufferCount == capacity}

    /// Returns whether or not the `CMBufferQueue` has been marked with EOD.
    public var containsEndOfData: Bool { bufferQueue.containsEndOfData }

    /// Returns whether or not the `CMBufferQueue` has been marked with EOD, and
    /// is now empty.
    public var isAtEndOfData: Bool { bufferQueue.isAtEndOfData }

    /// Gets the total size.
    ///
    /// The total size of the `CMBufferQueue` is the sum of all the individual
    /// buffer sizes, as reported by the `getTotalSize` handler. If there are no
    /// buffers in the queue, `0` will be returned.
    public var totalSize: Int { bufferQueue.totalSize }

    /// Gets the duration.
    ///
    /// The duration of the `CMBufferQueue` is the sum of all the individual
    /// buffer durations, as reported by the `getDuration` handler. If there are no
    /// buffers in the queue, `CMTime.zero` will be returned.
    public var duration: CMTime { bufferQueue.duration }

    /// Gets the earliest decode timestamp.
    ///
    /// The search for earliest decode timstamp is performed in this API.
    /// If you know your queue is in decode order, `firstDecodeTimeStamp` is a
    /// faster alternative. If the `getDecodeTimeStamp` handler is `nil`,
    /// `CMTime.invalid` will be returned.
    public var minDecodeTimeStamp: CMTime { bufferQueue.minDecodeTimeStamp }

    /// Gets the decode timestamp of the first buffer.
    ///
    /// This API is is a faster alternative to `minDecodeTimeStamp`, but only
    /// gives the same answer if your queue is in decode order.
    ///
    /// If the `getDecodeTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var firstDecodeTimeStamp: CMTime { bufferQueue.firstDecodeTimeStamp }

    /// Gets the earliest presentation timestamp.
    ///
    /// The search for earliest presentation timstamp is performed in this API. If
    /// you know your queue is sorted by presentation time,
    /// `firstPresentationTimeStamp` is a faster alternative. If the
    /// `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var minPresentationTimeStamp: CMTime { bufferQueue.minPresentationTimeStamp }

    /// Gets the presentation timestamp of the first buffer.
    ///
    /// This API is is a faster alternative to `minPresentationTimeStamp`, but
    /// only  works if you know your queue is sorted by presentation timestamp. If
    /// the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var firstPresentationTimeStamp: CMTime { bufferQueue.firstPresentationTimeStamp }

    /// Gets the greatest presentation timestamp.
    ///
    /// If the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will
    /// be returned.
    public var maxPresentationTimeStamp: CMTime { bufferQueue.maxPresentationTimeStamp }

    /// Gets the greatest end presentation timestamp.
    ///
    /// This is the maximum end time (PTS + duration) of buffers in the queue.
    /// If the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will
    /// be returned.
    public var endPresentationTimeStamp: CMTime { bufferQueue.endPresentationTimeStamp }

    /// Retrieves the next-to-dequeue buffer but leaves it in the queue.
    ///
    /// Note that with non-FIFO queues it's not guaranteed that the next dequeue
    /// will return this particular buffer (if an intervening enqueue adds a
    /// buffer that will dequeue next).
    public var head: T? { bufferQueue.head as? T }

    private let bufferQueue: CMBufferQueue
    private let capacity: CMItemCount

    public init(capacity: CMItemCount = 0, handlers: CMBufferQueue.Handlers = .outputPTSSortedSampleBuffers) throws {
        self.capacity = capacity
        bufferQueue = try CMBufferQueue(
            capacity: capacity,
            handlers: handlers
        )
    }

    public init(
        capacity: CMItemCount = 120,
        compareHandler: @escaping (_ lhs: T, _ rhs: T) -> CFComparisonResult,
        ptsHandler: ((T) -> CMTime)? = nil,
        durationHandler: ((T) -> CMTime)? = nil,
        isDataReady: ((T) -> Bool)? = nil,
    ) throws {
        self.capacity = capacity
        let handlers = CMBufferQueue.Handlers.unsortedSampleBuffers.withHandlers {
            $0.compare { lhs, rhs in
                return compareHandler(lhs as! T, rhs as! T)
            }
            $0.getDecodeTimeStamp { _ in return .zero }
            $0.getDuration { _ in return .zero }
            $0.getPresentationTimeStamp { buffer in
                ptsHandler?(buffer as! T) ?? .zero
            }
            $0.getSize { _ in return .zero }
            $0.isDataReady { isDataReady?($0 as! T) ?? true }
            if let durationHandler {
                $0.getDuration { durationHandler($0 as! T) }
            }
        }
        bufferQueue = try CMBufferQueue(
            capacity: capacity,
            handlers: handlers
        )
    }

    /// Installs a trigger.
    ///
    /// The returned trigger token can be passed to `testTrigger` and
    /// `removeTrigger`.
    ///
    /// The returned trigger can be discarded (client doesn't need to test or
    /// remove trigger), and the body parameter can be `nil` (client doesn't need
    /// callbacks, but rather will explicitly test the trigger). One of these two
    /// parameters must be non-`nil`, however, since an untestable trigger that
    /// does not perform a callback is meaningless. If the trigger condition is
    /// already true, `installTrigger` will call the `body`.
    ///
    /// - Parameters:
    ///   - condition: The condition to be tested when evaluating the trigger.
    ///   - body: Closure to be called when the trigger condition becomes true.
    ///     Can be `nil`, if client intends only to explicitly test the condition.
    /// - Returns: Trigger token which can be used with `testTrigger` and
    ///   `removeTrigger`. Can be discarded if client has no need to explicitly
    ///   test or remove the trigger.
    public func installTrigger(condition: CMBufferQueue.TriggerCondition, _ body: CMBufferQueueTriggerHandler? = nil) throws -> CMBufferQueue.TriggerToken {
        try bufferQueue.installTrigger(condition: condition, body)
    }

    /// Removes a previously installed trigger.
    ///
    /// Triggers will automatically be removed when a queue is finalized.
    /// However, if more than one module has access to a queue, it may be hard
    /// for an individual module to know when the queue is finalized since other
    /// modules may retain it. To address this concern, modules should remove
    /// their triggers before they themselves are finalized.
    ///
    /// - Parameter triggerToken: Trigger to remove from the queue
    public func removeTrigger(_ triggerToken: CMBufferQueue.TriggerToken) throws {
        try bufferQueue.removeTrigger(triggerToken)
    }

    /// Tests whether the trigger condition is true.
    ///
    /// Whereas the trigger callback will only be called when the condition goes
    /// from `false` to `true`, `testTrigger` always returns the condition's
    /// current status.
    /// The `triggerToken` must be one that has been installed on this queue.
    ///
    /// - Parameter triggerToken: Trigger to test.
    public func testTrigger(_ triggerToken: CMBufferQueue.TriggerToken) -> Bool {
        bufferQueue.testTrigger(triggerToken)
    }

    /// Enqueues a buffer.
    ///
    /// The `buffer` is retained by the queue, so the client can safely release
    /// the buffer if it has no further use for it.
    ///
    /// If the compare handler is not `nil`, this API performs an insertion sort
    /// using that compare operation.
    ///
    /// If the validation handler is not `nil`, this API calls it; if it throws,
    /// the buffer will not be enqueued and this API will rethrow the error.
    ///
    /// - Parameter buffer: The buffer to enqueue.
    public func enqueue(_ buffer: T) throws {
        try bufferQueue.enqueue(buffer)
    }

    /// Dequeues a buffer.
    ///
    /// - Returns: The dequeued buffer. Will be `nil` if the queue is empty.
    @discardableResult
    public func dequeue() -> T? {
        return (bufferQueue.dequeue() as! T?)
    }

    /// Dequeues a buffer if it is ready.
    ///
    /// - Returns: The dequeued buffer. Will be `nil` if the queue is empty, or if
    /// the buffer to be dequeued is not yet ready.
    public func dequeueIfDataReady() -> T? {
        (bufferQueue.dequeueIfDataReady() as! T?)
    }

    /// Marks the `CMBufferQueue` with EOD.
    ///
    /// All subsequent enqueues will be rejected until `reset()` is called.
    /// Subsequent dequeues will succeed as long as the queue is not empty.
    public func markEndOfData() throws {
        try bufferQueue.markEndOfData()
    }

    /// Resets the `CMBufferQueue`. Empties the queue, and clears any EOD mark.
    ///
    /// All buffers in the queue are released. Triggers are not removed, however,
    /// and will be called appropriately as the queue duration goes to `.zero`.
    public func reset() throws {
        try bufferQueue.reset()
    }
}

public extension TypedCMBufferQueue {
    enum Errors: OSStatus, Error {
        case allocationFailed = -12760
        case requiredParameterMissing = -12761
        case invalidCMBufferCallbacksStruct = -12762
        case enqueueAfterEndOfData = -12763
        case queueIsFull = -12764
        case badTriggerDuration = -12765
        case cannotModifyQueueFromTriggerCallback = -12766
        case invalidTriggerCondition = -12767
        case invalidTriggerToken = -12768
        case invalidBuffer = -12769
    }
}
