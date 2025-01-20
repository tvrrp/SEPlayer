//
//  TypedCMBufferQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public final class TypedCMBufferQueue<T: CMBuffer> {
    var head: T? { return (bufferQueue.head as! T?) }
    var buffers: CMBufferQueue.Buffers { bufferQueue.buffers }
    var isEmpty: Bool { return bufferQueue.isEmpty }
    var bufferCount: CMItemCount { return bufferQueue.bufferCount }
    var isFull: Bool { bufferCount == capacity}
    var totalSize: Int { bufferQueue.totalSize }
    var duration: CMTime { return bufferQueue.duration }
    var minDecodeTimeStamp: CMTime { return bufferQueue.minDecodeTimeStamp }
    var firstDecodeTimeStamp: CMTime { return bufferQueue.firstDecodeTimeStamp }
    var minPresentationTimeStamp: CMTime { return bufferQueue.minPresentationTimeStamp }
    var firstPresentationTimeStamp: CMTime { return bufferQueue.firstPresentationTimeStamp }
    var maxPresentationTimeStamp: CMTime { return bufferQueue.maxPresentationTimeStamp }
    var endPresentationTimeStamp: CMTime { return bufferQueue.endPresentationTimeStamp }

    private let bufferQueue: CMBufferQueue
    private let capacity: CMItemCount

    init(capacity: CMItemCount = 120, handlers: CMBufferQueue.Handlers = .outputPTSSortedSampleBuffers) throws {
        self.capacity = capacity
        bufferQueue = try CMBufferQueue(
            capacity: capacity,
            handlers: handlers
        )
    }

    func enqueue(_ buffer: T) throws {
        try bufferQueue.enqueue(buffer)
    }

    func dequeue() -> T? {
        return (bufferQueue.dequeue() as! T?)
    }

    func dequeueIfDataReady() -> T? {
        (bufferQueue.dequeueIfDataReady() as! T?)
    }
    
    func markEndOfData() throws {
        try bufferQueue.markEndOfData()
    }
    
    func reset() throws {
        try bufferQueue.reset()
    }

    public func reset(_ body: (CMBuffer) throws -> ()) throws {
        try bufferQueue.reset(body)
    }

    func installTrigger(condition: CMBufferQueue.TriggerCondition, _ body: CMBufferQueueTriggerHandler? = nil) throws -> CMBufferQueue.TriggerToken {
        try bufferQueue.installTrigger(condition: condition, body)
    }

    func removeTrigger(_ triggerToken: CMBufferQueue.TriggerToken) throws {
        try bufferQueue.removeTrigger(triggerToken)
    }

    func testTrigger(_ triggerToken: CMBufferQueue.TriggerToken) -> Bool {
        bufferQueue.testTrigger(triggerToken)
    }

    func setValidationHandler(_ body: @escaping (CMBufferQueue, CMBuffer) throws -> Void) {
        bufferQueue.setValidationHandler(body)
    }
}

private extension TypedCMBufferQueue {
    final class CMBufferCallbacksProvider {
        private let shouldCompareByPresentationTime: Bool

        init(shouldCompareByPresentationTime: Bool) {
            self.shouldCompareByPresentationTime = shouldCompareByPresentationTime
        }

        func getDecodeTime(buffer: CMBuffer) -> CMTime {
            return (buffer as! CMSampleBuffer).decodeTimeStamp
        }

        func getPresentationTime(buffer: CMBuffer) -> CMTime {
            return (buffer as! CMSampleBuffer).presentationTimeStamp
        }

        func getDuration(buffer: CMBuffer) -> CMTime {
            return (buffer as! CMSampleBuffer).duration
        }

        func compareBuffers(lhs: CMBuffer, rhs: CMBuffer) -> CFComparisonResult {
            let lhsTimestamp = shouldCompareByPresentationTime ? getPresentationTime(buffer: lhs) : getDecodeTime(buffer: lhs)
            let rhsTimestamp = shouldCompareByPresentationTime ? getPresentationTime(buffer: rhs) : getDecodeTime(buffer: rhs)
            if lhsTimestamp == rhsTimestamp { return .compareEqualTo }
            else if lhsTimestamp < rhsTimestamp { return .compareLessThan }
            else { return .compareGreaterThan }
        }

        func getSize(buffer: CMBuffer) -> Int {
            return (buffer as! CMSampleBuffer).totalSampleSize
        }
    }
}
