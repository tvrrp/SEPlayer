//
//  TypedCMBufferQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

final class TypedCMBufferQueue<T: CMBuffer> {
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

    init(
        capacity: CMItemCount = 120,
        compareHandler: @escaping (_ rhs: T, _ lhs: T) -> CFComparisonResult,
        ptsHandler: ((T) -> CMTime)? = nil
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
        }
        bufferQueue = try CMBufferQueue(
            capacity: capacity,
            handlers: handlers
        )
    }

    func head() -> T? {
        return if #available(iOS 17, *) {
            CMBufferQueueCopyHead(bufferQueue) as! T?
        } else {
            CMBufferQueueGetHead(bufferQueue) as! T?
        }
    }

    func enqueue(_ buffer: T) throws {
        try bufferQueue.enqueue(buffer)
    }

    @discardableResult
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
}

extension TypedCMBufferQueue {
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
