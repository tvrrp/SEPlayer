//
//  ReorderingBufferQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.08.2026.
//

import CoreMedia

/// A queue of buffers, ordered by presentation timestamp.
public final class ReorderingBufferQueue {
    public protocol OutputConsumer: AnyObject {
        /// Handles a buffer that is being removed from the queue.
        func consume(presentationTime: CMTime, buffer: inout BlockBufferReader) throws
    }

    /// Holds the presentation timestamp of a sample and its associated buffers.
    private struct BuffersWithTimestamp {
        let presentationTime: CMTime
        var nalBuffers: [BlockBufferReader]
    }

    private weak var outputConsumer: OutputConsumer?

    private var pendingBuffers: [BuffersWithTimestamp] = []
    private var reorderingQueueSize: Int?

    public init() {}

    /// Sets what receives the buffers as they leave the queue.
    public func setOutputConsumer(_ outputConsumer: OutputConsumer?) {
        self.outputConsumer = outputConsumer
    }

    /// Sets the max size of the re-ordering queue.
    ///
    /// The size is defined in terms of the number of unique presentation timestamps, rather than
    /// the number of buffers. This ensures that properties like H.264's `max_number_reorder_frames`
    /// can be used to set this max size in the case of multiple SEI messages per sample (where
    /// multiple SEI messages therefore have the same presentation timestamp).
    ///
    /// When the queue exceeds this size during a call to `add`, the buffers associated with the
    /// least timestamp are passed to the `OutputConsumer` provided during construction.
    ///
    /// If the new size is larger than the number of elements currently in the queue, items are
    /// removed from the head of the queue (least first) and passed to the `OutputConsumer`
    /// provided during construction.
    public func setMaxSize(_ reorderingQueueSize: Int) throws {
        precondition(reorderingQueueSize >= 0)
        self.reorderingQueueSize = reorderingQueueSize
        try flushQueueDownToSize(reorderingQueueSize)
    }

    /// Returns the maximum size of this queue, or `nil` if it is unbounded.
    ///
    /// See `setMaxSize(_:)` for details on how size is defined.
    public func getMaxSize() -> Int? { reorderingQueueSize }

    /// Adds a buffer to the queue.
    ///
    /// If this causes the queue to exceed its max size, buffers associated with the least
    /// timestamp (which may be the buffer passed to this method) are passed to the
    /// `OutputConsumer` provided during construction.
    ///
    /// Buffers with matching timestamps must be added consecutively (this will naturally happen
    /// when parsing buffers from a container).
    ///
    /// - Parameters:
    ///   - presentationTime: The presentation time of the buffer. An invalid time will cause the
    ///     buffer to be emitted immediately.
    ///   - buffer: The buffer data. The queue retains the underlying blocks, so the caller must not
    ///     mutate them after this method returns.
    public func add(presentationTime: CMTime, buffer: inout BlockBufferReader) throws {
        if !presentationTime.isNumeric
            || reorderingQueueSize == 0
            || (reorderingQueueSize.map {
                pendingBuffers.count >= $0 && presentationTime < pendingBuffers[0].presentationTime
            } ?? false) {
            try outputConsumer?.consume(presentationTime: presentationTime, buffer: &buffer)
            return
        }

        if let lastIndex = pendingBuffers.indices.last,
           pendingBuffers[lastIndex].presentationTime == presentationTime {
            pendingBuffers[lastIndex].nalBuffers.append(buffer)
            return
        }

        let insertionIndex = pendingBuffers.firstIndex {
            $0.presentationTime > presentationTime
        } ?? pendingBuffers.endIndex

        if insertionIndex > pendingBuffers.startIndex,
           pendingBuffers[insertionIndex - 1].presentationTime == presentationTime {
            pendingBuffers[insertionIndex - 1].nalBuffers.append(buffer)
            return
        }

        pendingBuffers.insert(
            BuffersWithTimestamp(presentationTime: presentationTime, nalBuffers: [buffer]),
            at: insertionIndex
        )

        if let reorderingQueueSize {
            try flushQueueDownToSize(reorderingQueueSize)
        }
    }

    /// Empties the queue, discarding all previously added buffers.
    public func clear() {
        pendingBuffers.removeAll(keepingCapacity: true)
    }

    /// Empties the queue, passing all buffers (least first) to the `OutputConsumer` provided
    /// during construction.
    public func flush() throws {
        try flushQueueDownToSize(0)
    }

    private func flushQueueDownToSize(_ targetSize: Int) throws {
        while pendingBuffers.count > targetSize {
            let group = pendingBuffers.removeFirst()
            for var nalBuffer in group.nalBuffers {
                try outputConsumer?.consume(presentationTime: group.presentationTime, buffer: &nalBuffer)
            }
        }
    }
}
