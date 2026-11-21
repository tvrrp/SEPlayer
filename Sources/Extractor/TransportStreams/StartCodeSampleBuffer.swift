//
//  StartCodeSampleBuffer.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Keeps the bytes of a stream of start code delimited units, such as MPEG-2 video, until the sample they belong to
/// ends.
final class StartCodeSampleBuffer {
    private let allocator: CFAllocator
    /// Where the samples are copied to.
    private let sampleMemory: SampleMemory

    /// One block of memory, so that the bytes kept can be moved to its start.
    private var buffer: CMBlockBuffer
    /// The number of bytes kept.
    private var length = 0
    /// The position in the stream of the first byte kept.
    private var startPosition = 0

    init(memoryPool: CMMemoryPool) throws {
        allocator = memoryPool.allocator
        sampleMemory = SampleMemory(allocator: allocator, blockSize: 512 * 1024) // 512 KB
        buffer = try CMBlockBuffer(length: Self.initialCapacity, allocator: allocator, flags: .assureMemoryNow)
    }

    func append(_ data: BlockBufferView) throws {
        guard !data.isEmpty else { return }
        try ensureCapacity(length + data.count)
        let copied = try data.withContiguousStorageIfAvailable { bytes in
            try buffer.replaceDataBytes(with: UnsafeRawBufferPointer(bytes), atOffset: length)
            return bytes.count
        }
        length += copied ?? 0
    }

    /// The bytes before `position` in the stream, which are no longer kept.
    func take(upTo position: Int) throws -> CMBlockBuffer? {
        let count = min(max(position - startPosition, 0), length)
        guard count > 0 else { return nil }
        let sample = try sampleMemory.copy(buffer, range: 0 ..< count)
        try discard(upTo: position)
        return sample
    }

    /// Drops the bytes before `position` in the stream.
    func discard(upTo position: Int) throws {
        let count = min(max(position - startPosition, 0), length)
        guard count > 0 else { return }
        let remaining = length - count
        if remaining > 0 {
            try buffer.withUnsafeMutableBlockBytes { bytes in
                bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[count ..< length]))
            }
        }
        length = remaining
        startPosition += count
    }

    func reset() {
        length = 0
        startPosition = 0
    }

    /// Moves the bytes kept to a block of at least `required` bytes, if the block is smaller.
    private func ensureCapacity(_ required: Int) throws {
        guard required > buffer.dataLength else { return }
        var capacity = buffer.dataLength
        while capacity < required {
            capacity *= 2
        }
        let grown = try CMBlockBuffer(length: capacity, allocator: allocator, flags: .assureMemoryNow)
        if length > 0 {
            try grown.withUnsafeMutableBlockBytes { destination in
                try buffer.copyDataBytes(to: UnsafeMutableRawBufferPointer(rebasing: destination.prefix(length)))
            }
        }
        buffer = grown
    }
}

private extension StartCodeSampleBuffer {
    static let initialCapacity = 64 * 1024 // 64 KB
}
