//
//  TypedCMBufferQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public final class TypedCMBufferQueue<T: CMBuffer>: @unchecked Sendable {
    /// The buffers in the queue, in the order they dequeue.
    public var buffers: [T] {
        allBuffers(of: bufferQueue).map { $0 as! T }
    }

    /// Returns whether or not the `CMBufferQueue` is empty.
    public var isEmpty: Bool { CMBufferQueueIsEmpty(bufferQueue) }

    /// Gets the number of buffers in the queue.
    public var bufferCount: CMItemCount { CMBufferQueueGetBufferCount(bufferQueue) }

    /// Returns whether or not the `CMBufferQueue` is full.
    public var isFull: Bool { bufferCount == capacity }

    /// Returns whether or not the `CMBufferQueue` has been marked with EOD.
    public var containsEndOfData: Bool { CMBufferQueueContainsEndOfData(bufferQueue) }

    /// Returns whether or not the `CMBufferQueue` has been marked with EOD, and
    /// is now empty.
    public var isAtEndOfData: Bool { CMBufferQueueIsAtEndOfData(bufferQueue) }

    /// Gets the total size.
    ///
    /// The total size of the `CMBufferQueue` is the sum of all the individual
    /// buffer sizes, as reported by the `getTotalSize` handler. If there are no
    /// buffers in the queue, `0` will be returned.
    public var totalSize: Int { CMBufferQueueGetTotalSize(bufferQueue) }

    /// Gets the duration.
    ///
    /// The duration of the `CMBufferQueue` is the sum of all the individual
    /// buffer durations, as reported by the `getDuration` handler. If there are no
    /// buffers in the queue, `CMTime.zero` will be returned.
    public var duration: CMTime { CMBufferQueueGetDuration(bufferQueue) }

    /// Gets the earliest decode timestamp.
    ///
    /// The search for earliest decode timstamp is performed in this API.
    /// If you know your queue is in decode order, `firstDecodeTimeStamp` is a
    /// faster alternative. If the `getDecodeTimeStamp` handler is `nil`,
    /// `CMTime.invalid` will be returned.
    public var minDecodeTimeStamp: CMTime { CMBufferQueueGetMinDecodeTimeStamp(bufferQueue) }

    /// Gets the decode timestamp of the first buffer.
    ///
    /// This API is is a faster alternative to `minDecodeTimeStamp`, but only
    /// gives the same answer if your queue is in decode order.
    ///
    /// If the `getDecodeTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var firstDecodeTimeStamp: CMTime { CMBufferQueueGetFirstDecodeTimeStamp(bufferQueue) }

    /// Gets the earliest presentation timestamp.
    ///
    /// The search for earliest presentation timstamp is performed in this API. If
    /// you know your queue is sorted by presentation time,
    /// `firstPresentationTimeStamp` is a faster alternative. If the
    /// `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var minPresentationTimeStamp: CMTime { CMBufferQueueGetMinPresentationTimeStamp(bufferQueue) }

    /// Gets the presentation timestamp of the first buffer.
    ///
    /// This API is is a faster alternative to `minPresentationTimeStamp`, but
    /// only  works if you know your queue is sorted by presentation timestamp. If
    /// the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will be
    /// returned.
    public var firstPresentationTimeStamp: CMTime { CMBufferQueueGetFirstPresentationTimeStamp(bufferQueue) }

    /// Gets the greatest presentation timestamp.
    ///
    /// If the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will
    /// be returned.
    public var maxPresentationTimeStamp: CMTime { CMBufferQueueGetMaxPresentationTimeStamp(bufferQueue) }

    /// Gets the greatest end presentation timestamp.
    ///
    /// This is the maximum end time (PTS + duration) of buffers in the queue.
    /// If the `getPresentationTimeStamp` handler is `nil`, `CMTime.invalid` will
    /// be returned.
    public var endPresentationTimeStamp: CMTime { CMBufferQueueGetEndPresentationTimeStamp(bufferQueue) }

    /// Retrieves the next-to-dequeue buffer but leaves it in the queue.
    ///
    /// Note that with non-FIFO queues it's not guaranteed that the next dequeue
    /// will return this particular buffer (if an intervening enqueue adds a
    /// buffer that will dequeue next).
    public var head: T? { CMBufferQueueGetHead(bufferQueue) as? T }

    private let bufferQueue: CMBufferQueue
    private let capacity: CMItemCount
    /// The handlers of a queue with its own order: the queue only refers to them.
    private var handlers: BufferQueueHandlers?

    /// How a queue orders its buffers.
    public enum Ordering: Sendable {
        /// In the order they are enqueued.
        case unsorted
        /// By output presentation time, for sample buffers.
        case outputPresentationTime
    }

    /// A queue of sample buffers.
    ///
    /// - Parameter capacity: The most buffers the queue holds; 0 for no limit.
    public init(capacity: CMItemCount = 0, ordering: Ordering = .outputPresentationTime) throws(BufferQueueError) {
        self.capacity = capacity
        let callbacks = switch ordering {
        case .unsorted: CMBufferQueueGetCallbacksForUnsortedSampleBuffers()
        case .outputPresentationTime: CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS()
        }
        var queue: CMBufferQueue?
        let status = CMBufferQueueCreate(allocator: kCFAllocatorDefault, capacity: capacity, callbacks: callbacks, queueOut: &queue)
        guard status == noErr, let queue else {
            throw BufferQueueError(status: status)
        }
        bufferQueue = queue
    }

    /// A queue of any buffers, ordered by `compareHandler`.
    public init(
        capacity: CMItemCount = 120,
        compareHandler: @escaping (_ lhs: T, _ rhs: T) -> CFComparisonResult,
        ptsHandler: ((T) -> CMTime)? = nil,
        durationHandler: ((T) -> CMTime)? = nil,
        isDataReady: ((T) -> Bool)? = nil
    ) throws(BufferQueueError) {
        self.capacity = capacity
        let handlers = BufferQueueHandlers(
            compare: { compareHandler($0 as! T, $1 as! T) },
            presentationTimeStamp: { ptsHandler?($0 as! T) ?? .zero },
            duration: { durationHandler?($0 as! T) ?? .zero },
            isDataReady: { isDataReady?($0 as! T) ?? true }
        )
        self.handlers = handlers
        var callbacks = handlers.callbacks()
        var queue: CMBufferQueue?
        let status = CMBufferQueueCreate(allocator: kCFAllocatorDefault, capacity: capacity, callbacks: &callbacks, queueOut: &queue)
        guard status == noErr, let queue else {
            throw BufferQueueError(status: status)
        }
        bufferQueue = queue
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
    public func installTrigger(
        condition: TriggerCondition,
        _ body: CMBufferQueueTriggerHandler? = nil
    ) throws(BufferQueueError) -> CMBufferQueueTriggerToken {
        var token: CMBufferQueueTriggerToken?
        let status: OSStatus = switch condition {
        case let .whenBufferCountBecomesLessThan(count):
            installTrigger(kCMBufferQueueTrigger_WhenBufferCountBecomesLessThan, count: count, &token, body)
        case let .whenBufferCountBecomesGreaterThan(count):
            installTrigger(kCMBufferQueueTrigger_WhenBufferCountBecomesGreaterThan, count: count, &token, body)
        case let .whenDurationBecomesLessThan(time):
            installTrigger(kCMBufferQueueTrigger_WhenDurationBecomesLessThan, time: time, &token, body)
        case let .whenDurationBecomesLessThanOrEqualTo(time):
            installTrigger(kCMBufferQueueTrigger_WhenDurationBecomesLessThanOrEqualTo, time: time, &token, body)
        case let .whenDurationBecomesGreaterThan(time):
            installTrigger(kCMBufferQueueTrigger_WhenDurationBecomesGreaterThan, time: time, &token, body)
        case let .whenDurationBecomesGreaterThanOrEqualTo(time):
            installTrigger(kCMBufferQueueTrigger_WhenDurationBecomesGreaterThanOrEqualTo, time: time, &token, body)
        case .whenMinPresentationTimeStampChanges:
            installTrigger(kCMBufferQueueTrigger_WhenMinPresentationTimeStampChanges, time: .zero, &token, body)
        case .whenMaxPresentationTimeStampChanges:
            installTrigger(kCMBufferQueueTrigger_WhenMaxPresentationTimeStampChanges, time: .zero, &token, body)
        case .whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo:
            // Buffer queues have no such trigger.
            kCMBufferQueueError_InvalidTriggerCondition
        case .whenDataBecomesReady:
            installTrigger(kCMBufferQueueTrigger_WhenDataBecomesReady, time: .zero, &token, body)
        case .whenEndOfDataReached:
            installTrigger(kCMBufferQueueTrigger_WhenEndOfDataReached, time: .zero, &token, body)
        case .whenReset:
            installTrigger(kCMBufferQueueTrigger_WhenReset, time: .zero, &token, body)
        }
        guard status == noErr, let token else {
            throw BufferQueueError(status: status)
        }
        return token
    }

    private func installTrigger(
        _ condition: CMBufferQueueTriggerCondition,
        time: CMTime,
        _ token: inout CMBufferQueueTriggerToken?,
        _ body: CMBufferQueueTriggerHandler?
    ) -> OSStatus {
        guard let body else {
            return CMBufferQueueInstallTrigger(bufferQueue, callback: nil, refcon: nil, condition: condition, time: time, triggerTokenOut: &token)
        }
        return CMBufferQueueInstallTriggerHandler(bufferQueue, condition, time, &token, body)
    }

    private func installTrigger(
        _ condition: CMBufferQueueTriggerCondition,
        count: Int,
        _ token: inout CMBufferQueueTriggerToken?,
        _ body: CMBufferQueueTriggerHandler?
    ) -> OSStatus {
        guard let body else {
            return CMBufferQueueInstallTriggerWithIntegerThreshold(bufferQueue, callback: nil, refcon: nil, condition: condition, threshold: count, triggerTokenOut: &token)
        }
        return CMBufferQueueInstallTriggerHandlerWithIntegerThreshold(bufferQueue, condition, count, &token, body)
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
    public func removeTrigger(_ triggerToken: CMBufferQueueTriggerToken) throws(BufferQueueError) {
        let status = CMBufferQueueRemoveTrigger(bufferQueue, triggerToken: triggerToken)
        guard status == noErr else { throw BufferQueueError(status: status) }
    }

    /// Tests whether the trigger condition is true.
    ///
    /// Whereas the trigger callback will only be called when the condition goes
    /// from `false` to `true`, `testTrigger` always returns the condition's
    /// current status.
    /// The `triggerToken` must be one that has been installed on this queue.
    ///
    /// - Parameter triggerToken: Trigger to test.
    public func testTrigger(_ triggerToken: CMBufferQueueTriggerToken) -> Bool {
        CMBufferQueueTestTrigger(bufferQueue, triggerToken: triggerToken)
    }

    /// Enqueues a buffer.
    ///
    /// The `buffer` is retained by the queue, so the client can safely release
    /// the buffer if it has no further use for it.
    ///
    /// If the compare handler is not `nil`, this API performs an insertion sort
    /// using that compare operation.
    ///
    /// - Parameter buffer: The buffer to enqueue.
    public func enqueue(_ buffer: T) throws(BufferQueueError) {
        let status = CMBufferQueueEnqueue(bufferQueue, buffer: buffer)
        guard status == noErr else { throw BufferQueueError(status: status) }
    }

    /// Dequeues a buffer.
    ///
    /// - Returns: The dequeued buffer. Will be `nil` if the queue is empty.
    @discardableResult
    public func dequeue() -> T? {
        CMBufferQueueDequeue(bufferQueue) as! T?
    }

    /// Dequeues a buffer if it is ready.
    ///
    /// - Returns: The dequeued buffer. Will be `nil` if the queue is empty, or if
    /// the buffer to be dequeued is not yet ready.
    public func dequeueIfDataReady() -> T? {
        CMBufferQueueDequeueIfDataReady(bufferQueue) as! T?
    }

    /// Marks the `CMBufferQueue` with EOD.
    ///
    /// All subsequent enqueues will be rejected until `reset()` is called.
    /// Subsequent dequeues will succeed as long as the queue is not empty.
    public func markEndOfData() throws(BufferQueueError) {
        let status = CMBufferQueueMarkEndOfData(bufferQueue)
        guard status == noErr else { throw BufferQueueError(status: status) }
    }

    /// Resets the `CMBufferQueue`. Empties the queue, and clears any EOD mark.
    ///
    /// All buffers in the queue are released. Triggers are not removed, however,
    /// and will be called appropriately as the queue duration goes to `.zero`.
    public func reset() throws(BufferQueueError) {
        let status = CMBufferQueueReset(bufferQueue)
        guard status == noErr else { throw BufferQueueError(status: status) }
    }
}

/// The buffers of `queue`, in the order they dequeue.
private func allBuffers(of queue: CMBufferQueue) -> [CMBuffer] {
    var buffers: [CMBuffer] = []
    withUnsafeMutablePointer(to: &buffers) { buffers in
        _ = CMBufferQueueCallForEachBuffer(queue, callback: { buffer, refcon in
            refcon!.assumingMemoryBound(to: [CMBuffer].self).pointee.append(buffer)
            return noErr
        }, refcon: buffers)
    }
    return buffers
}

/// What a queue with its own order asks about its buffers.
private final class BufferQueueHandlers {
    let compare: (CMBuffer, CMBuffer) -> CFComparisonResult
    let presentationTimeStamp: (CMBuffer) -> CMTime
    let duration: (CMBuffer) -> CMTime
    let isDataReady: (CMBuffer) -> Bool

    init(
        compare: @escaping (CMBuffer, CMBuffer) -> CFComparisonResult,
        presentationTimeStamp: @escaping (CMBuffer) -> CMTime,
        duration: @escaping (CMBuffer) -> CMTime,
        isDataReady: @escaping (CMBuffer) -> Bool
    ) {
        self.compare = compare
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.isDataReady = isDataReady
    }

    /// The callbacks of the queue, which refer to these handlers without keeping them.
    func callbacks() -> CMBufferCallbacks {
        CMBufferCallbacks(
            version: 0,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            getDecodeTimeStamp: { _, _ in .zero },
            getPresentationTimeStamp: { buffer, refcon in BufferQueueHandlers.of(refcon).presentationTimeStamp(buffer) },
            getDuration: { buffer, refcon in BufferQueueHandlers.of(refcon).duration(buffer) },
            isDataReady: { buffer, refcon in DarwinBoolean(BufferQueueHandlers.of(refcon).isDataReady(buffer)) },
            compare: { lhs, rhs, refcon in BufferQueueHandlers.of(refcon).compare(lhs, rhs) },
            dataBecameReadyNotification: nil,
            getSize: { _, _ in 0 }
        )
    }

    private static func of(_ refcon: UnsafeMutableRawPointer?) -> BufferQueueHandlers {
        Unmanaged<BufferQueueHandlers>.fromOpaque(refcon!).takeUnretainedValue()
    }
}
