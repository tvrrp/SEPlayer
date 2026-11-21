//
//  SampleMemory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// Copies the bytes of samples into blocks of memory that the samples written one after another share.
///
/// The bytes of a transport stream sample are spread over its packets. A reference to them as they were read keeps
/// every buffer read alive until the sample goes, most of it other streams' bytes. A block of its own for each sample
/// is rounded up to whole pages, a third more memory for the samples of tens of kilobytes a video has. A block goes when
/// the last of its samples does.
final class SampleMemory {
    private let allocator: CFAllocator?
    private let blockSize: Int

    private var block: CMBlockBuffer?
    /// Where in the block the next copy goes.
    private var position = 0

    /// - Parameter blockSize: The size of the blocks; a copy that is larger gets a block of its size.
    init(allocator: CFAllocator? = kCFAllocatorDefault, blockSize: Int) {
        self.allocator = allocator
        self.blockSize = blockSize
    }

    /// A copy of `range` of `source`, all of it without one.
    func copy(_ source: CMBlockBuffer, range: Range<Int>? = nil) throws -> CMBlockBuffer {
        let range = range ?? 0 ..< source.dataLength
        return try makeCopy(length: range.count) { destination in
            try source.copyDataBytes(atOffset: range.lowerBound, to: destination)
        }
    }

    /// A copy of the next `length` bytes of `data`, which it moves past.
    func copy(from data: inout BlockBufferReader, length: Int) throws -> CMBlockBuffer {
        let copy = try copy(data.blockBuffer, range: data.readerIndex ..< data.readerIndex + length)
        data.moveReaderIndex(forwardBy: length)
        return copy
    }

    /// A copy of `bytes`.
    func copy(bytes: UnsafeRawBufferPointer) throws -> CMBlockBuffer {
        try makeCopy(length: bytes.count) { $0.copyMemory(from: bytes) }
    }

    /// Takes `length` bytes of the block, a new one if the current one has no room, and lets `fill` write them.
    private func makeCopy(
        length: Int,
        fill: (UnsafeMutableRawBufferPointer) throws -> Void
    ) throws -> CMBlockBuffer {
        guard length > 0 else { return try CMBlockBuffer() }

        let block: CMBlockBuffer
        if let current = self.block, position + length <= current.dataLength {
            block = current
        } else {
            block = try CMBlockBuffer(length: max(blockSize, length), allocator: allocator, flags: .assureMemoryNow)
            self.block = block
            position = 0
        }
        try block.withUnsafeMutableBlockBytes(at: position) { destination in
            try fill(UnsafeMutableRawBufferPointer(rebasing: destination.prefix(length)))
        }
        let copy = try CMBlockBuffer(bufferReference: block, range: position ..< (position + length))
        position += length
        return copy
    }
}
