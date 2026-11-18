//
//  SampleDataQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia
import SEPlayerCommon

/// The bytes of a sample queue, as the extractor wrote them: each buffer it wrote is kept as it is, without copying,
/// at its position in the stream of bytes.
///
/// A read references the buffers its range covers; discarding drops the buffers before a position. Neither depends on
/// how much is queued: one buffer of everything would have to be referenced anew after every discard, a cost that grows
/// with the buffer and with each piece written into it, as the small payloads of MPEG-TS.
///
/// The extractor writes from the task that loads, and the sample queue reads and discards on the player's queue: each
/// call holds the lock while it runs.
final class SampleDataQueue: @unchecked Sendable {
    private struct Chunk {
        /// The position of the chunk's first byte in the stream of bytes.
        let start: Int
        let buffer: CMBlockBuffer
        var end: Int { start + buffer.dataLength }
    }

    /// Where the buffers the queue lets go are released.
    ///
    /// The last reference to a downloaded block hands it back to the cache, which makes it volatile or frees it: a
    /// system call or two a block. A seek lets go of the whole buffer at once, tens of milliseconds the player would
    /// otherwise wait for.
    private static let releaseQueue = DispatchQueue(label: "SampleDataQueue.release", qos: .utility)

    private let lock = UnfairLock()
    /// Hears how many bytes the queue holds.
    private let allocator: Allocator?

    /// The written buffers, from `firstChunk` on; the ones before it are discarded, and dropped from the array in
    /// batches.
    private var chunks: [Chunk] = []
    private var firstChunk = 0
    /// The position before which the bytes are discarded.
    private var baseOffset = 0
    private var totalBytesWritten = 0
    /// The bytes reported to the allocator.
    private var reportedBytes = 0

    init(allocator: Allocator? = nil) {
        self.allocator = allocator
    }

    deinit {
        allocator?.release(bytes: reportedBytes)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        release(chunks[...])
        chunks.removeAll()
        firstChunk = 0
        baseOffset = 0
        totalBytesWritten = 0
        reportHeldBytes()
    }

    func discardUpstreamSampleBytes(totalBytesWritten: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        precondition(totalBytesWritten <= self.totalBytesWritten)

        guard totalBytesWritten < self.totalBytesWritten else { return }
        defer { reportHeldBytes() }
        // Every sample is gone, the read ones included: nothing kept is left, so writing starts
        // over from there. With no samples the queue reports 0, which can be behind data that
        // has already been discarded downstream.
        guard totalBytesWritten > baseOffset else {
            release(chunks[...])
            chunks.removeAll()
            firstChunk = 0
            baseOffset = totalBytesWritten
            self.totalBytesWritten = totalBytesWritten
            return
        }

        var removed = chunks.endIndex
        while removed > firstChunk, chunks[removed - 1].start >= totalBytesWritten {
            removed -= 1
        }
        release(chunks[removed...])
        chunks.removeSubrange(removed...)
        if let last = chunks.last, chunks.count > firstChunk, last.end > totalBytesWritten {
            let kept = try CMBlockBuffer(bufferReference: last.buffer, range: 0 ..< (totalBytesWritten - last.start))
            chunks[chunks.count - 1] = Chunk(start: last.start, buffer: kept)
        }
        self.totalBytesWritten = totalBytesWritten
    }

    func readBuffer(range: Range<Int>) throws -> CMBlockBuffer {
        lock.lock()
        defer { lock.unlock() }
        precondition(range.lowerBound >= baseOffset)
        precondition(range.upperBound <= totalBytesWritten)

        guard !range.isEmpty else { return try CMBlockBuffer() }
        var index = chunkIndex(containing: range.lowerBound)
        let first = chunks[index]
        // Most samples lie within one written buffer.
        if range.upperBound <= first.end {
            return try CMBlockBuffer(bufferReference: first.buffer, range: (range.lowerBound - first.start) ..< (range.upperBound - first.start))
        }

        let buffer = try CMBlockBuffer()
        var position = range.lowerBound
        while position < range.upperBound {
            let chunk = chunks[index]
            let end = min(range.upperBound, chunk.end)
            try buffer.append(bufferReference: chunk.buffer, range: (position - chunk.start) ..< (end - chunk.start))
            position = end
            index += 1
        }
        return buffer
    }

    func discardDownstreamTo(absolutePosition: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let absolutePosition, absolutePosition > baseOffset else {
            return
        }
        precondition(absolutePosition <= totalBytesWritten)

        baseOffset = absolutePosition
        while firstChunk < chunks.count, chunks[firstChunk].end <= absolutePosition {
            firstChunk += 1
        }
        // The discarded ones go in batches, so the array moves its elements rarely.
        if firstChunk >= 256, firstChunk * 2 >= chunks.count {
            release(chunks[..<firstChunk])
            chunks.removeFirst(firstChunk)
            firstChunk = 0
        }
        reportHeldBytes()
    }

    func getTotalBytesWritten() -> Int {
        lock.withLock { totalBytesWritten }
    }

    func loadSampleData(buffer: CMBlockBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let length = buffer.dataLength
        guard length > 0 else { return }
        chunks.append(Chunk(start: totalBytesWritten, buffer: buffer))
        totalBytesWritten += length
        reportHeldBytes()
    }

    /// Releases `chunks` on the release queue, once the queue holds no other reference to them.
    private func release(_ chunks: ArraySlice<Chunk>) {
        guard !chunks.isEmpty else { return }
        let buffers = chunks.map(\.buffer)
        Self.releaseQueue.async { withExtendedLifetime(buffers) {} }
    }

    /// The index of the chunk that holds the byte at `position`, which must be held.
    private func chunkIndex(containing position: Int) -> Int {
        var low = firstChunk
        var high = chunks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chunks[middle].start <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Tells the allocator how much the held bytes changed since the last report.
    private func reportHeldBytes() {
        guard let allocator else { return }
        let heldBytes = totalBytesWritten - baseOffset
        if heldBytes > reportedBytes {
            allocator.allocate(bytes: heldBytes - reportedBytes)
        } else if heldBytes < reportedBytes {
            allocator.release(bytes: reportedBytes - heldBytes)
        }
        reportedBytes = heldBytes
    }
}
