//
//  CMBlockBuffer+Swift.swift
//  SEPlayer
//
//  Created by tvrrp on 11.10.2026.
//

import CoreMedia
import Foundation

// A block buffer's bytes run from offset 0 to `dataLength`. Calls that take a `range` work on those bytes of it; without
// one, on all of them.
//
// No flags are `.init()`, not `[]`: the empty literal makes the flags through the standard library's unspecialized
// set algebra, a cost on every slice of a transport stream packet.

public extension _CoreMediaInitializable where Self == CMBlockBuffer {
    /// An empty block buffer, for blocks and references to be appended to.
    ///
    /// - Parameter capacity: How many blocks it holds before it grows.
    init(capacity: Int = 0, flags: CMBlockBuffer.Flags = .init()) throws(BlockBufferError) {
        var buffer: CMBlockBuffer?
        let status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: UInt32(clamping: capacity),
            flags: flags.rawValue,
            blockBufferOut: &buffer
        )
        guard status == noErr, let buffer else {
            throw BlockBufferError(status: status)
        }
        self = buffer
    }

    /// A block buffer of a new memory block of `length` bytes.
    ///
    /// - Parameters:
    ///   - allocator: Where the memory comes from, such as a memory pool's.
    ///   - range: The bytes of the block the buffer holds; all of them by default.
    ///   - flags: `.assureMemoryNow` allocates the memory at once rather than when it is first used.
    init(
        length: Int,
        allocator: CFAllocator? = kCFAllocatorDefault,
        range: Range<Int>? = nil,
        flags: CMBlockBuffer.Flags = .init()
    ) throws(BlockBufferError) {
        var buffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: allocator,
            customBlockSource: nil,
            offsetToData: range?.lowerBound ?? 0,
            dataLength: range?.count ?? length,
            flags: flags.rawValue,
            blockBufferOut: &buffer
        )
        guard status == noErr, let buffer else {
            throw BlockBufferError(status: status)
        }
        self = buffer
    }

    /// A block buffer that references `range` of `buffer`, without copying its bytes. No bytes make an empty buffer.
    init(bufferReference buffer: CMBlockBuffer, range: Range<Int>? = nil, flags: CMBlockBuffer.Flags = .init()) throws(BlockBufferError) {
        let range = range ?? 0..<buffer.dataLength
        // A length of 0 would reference all of the buffer from the offset.
        guard !range.isEmpty else {
            try self.init()
            return
        }
        var reference: CMBlockBuffer?
        let status = CMBlockBufferCreateWithBufferReference(
            allocator: kCFAllocatorDefault,
            referenceBuffer: buffer,
            offsetToData: range.lowerBound,
            dataLength: range.count,
            flags: flags.rawValue,
            blockBufferOut: &reference
        )
        guard status == noErr, let reference else {
            throw BlockBufferError(status: status)
        }
        self = reference
    }
}

public extension CMBlockBuffer {
    /// How many bytes the buffer holds.
    var dataLength: Int {
        CMBlockBufferGetDataLength(self)
    }

    /// Whether all of the bytes are in one memory block.
    var isContiguous: Bool {
        isContiguous(in: 0..<dataLength)
    }

    /// Whether the bytes of `range` are in one memory block.
    func isContiguous(in range: Range<Int>) -> Bool {
        range.isEmpty || CMBlockBufferIsRangeContiguous(self, atOffset: range.lowerBound, length: range.count)
    }

    // MARK: - Appending

    /// Appends a new memory block of `length` bytes.
    func appendMemoryBlock(
        length: Int,
        allocator: CFAllocator? = kCFAllocatorDefault,
        range: Range<Int>? = nil,
        flags: CMBlockBuffer.Flags = .init()
    ) throws(BlockBufferError) {
        let status = CMBlockBufferAppendMemoryBlock(
            self,
            memoryBlock: nil,
            length: length,
            blockAllocator: allocator,
            customBlockSource: nil,
            offsetToData: range?.lowerBound ?? 0,
            dataLength: range?.count ?? length,
            flags: flags.rawValue
        )
        guard status == noErr else { throw BlockBufferError(status: status) }
    }

    /// Appends the memory of `buffer` without copying it; `deallocator` is called once the block buffers no longer use
    /// it.
    func appendMemoryBlock(
        _ buffer: UnsafeMutableRawBufferPointer,
        deallocator: @escaping (UnsafeMutableRawPointer, Int) -> Void,
        flags: CMBlockBuffer.Flags = .init()
    ) throws(BlockBufferError) {
        guard let baseAddress = buffer.baseAddress else {
            throw .badPointerParameter
        }
        let release = BlockRelease(deallocator)
        var source = release.blockSource()
        let status = CMBlockBufferAppendMemoryBlock(
            self,
            memoryBlock: baseAddress,
            length: buffer.count,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: buffer.count,
            flags: flags.rawValue
        )
        guard status == noErr else {
            // The block wasn't taken: nothing calls the release.
            release.discard()
            throw BlockBufferError(status: status)
        }
    }

    /// Appends a reference to `range` of `buffer`, without copying its bytes. No bytes append nothing.
    func append(bufferReference buffer: CMBlockBuffer, range: Range<Int>? = nil, flags: CMBlockBuffer.Flags = .init()) throws(BlockBufferError) {
        let range = range ?? 0..<buffer.dataLength
        // A length of 0 would reference all of the buffer from the offset.
        guard !range.isEmpty else { return }
        let status = CMBlockBufferAppendBufferReference(
            self,
            targetBBuf: buffer,
            offsetToData: range.lowerBound,
            dataLength: range.count,
            flags: flags.rawValue
        )
        guard status == noErr else { throw BlockBufferError(status: status) }
    }

    /// A block buffer with the bytes of `range` in one memory block: this one, or a reference to it, when they already
    /// are, or a copy.
    ///
    /// - Parameters:
    ///   - allocator: Where the memory of a copy comes from.
    ///   - flags: `.alwaysCopyData` copies even contiguous bytes.
    func makeContiguous(
        range: Range<Int>? = nil,
        allocator: CFAllocator? = kCFAllocatorDefault,
        flags: CMBlockBuffer.Flags = .init()
    ) throws(BlockBufferError) -> CMBlockBuffer {
        let range = range ?? 0..<dataLength
        guard !range.isEmpty else { return try CMBlockBuffer() }
        var buffer: CMBlockBuffer?
        let status = CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: self,
            blockAllocator: allocator,
            customBlockSource: nil,
            offsetToData: range.lowerBound,
            dataLength: range.count,
            flags: flags.rawValue,
            blockBufferOut: &buffer
        )
        guard status == noErr, let buffer else {
            throw BlockBufferError(status: status)
        }
        return buffer
    }

    // MARK: - Bytes

    /// Calls `body` with the bytes of `range` in one piece of memory, copied into one when they are in several blocks.
    func withContiguousStorage<R>(in range: Range<Int>? = nil, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        let range = range ?? 0..<dataLength
        guard !range.isEmpty else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        let buffer = isContiguous(in: range) ? self : try makeContiguous(range: range)
        let offset = buffer === self ? range.lowerBound : 0
        return try buffer.withUnsafeMutableBlockBytes(at: offset) { bytes in
            try body(UnsafeRawBufferPointer(rebasing: bytes.prefix(range.count)))
        }
    }

    /// Calls `body` with the memory of the block that holds the byte at `offset`, from that byte to the end of the
    /// block.
    func withUnsafeMutableBlockBytes<R>(at offset: Int = 0, _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        var lengthAtOffset = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            self,
            atOffset: offset,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer else {
            throw BlockBufferError(status: status)
        }
        return try body(UnsafeMutableRawBufferPointer(start: pointer, count: lengthAtOffset))
    }

    /// A copy of the bytes of `range`.
    func dataBytes(in range: Range<Int>? = nil) throws(BlockBufferError) -> Data {
        let range = range ?? 0..<dataLength
        var data = Data(count: range.count)
        guard !range.isEmpty else { return data }
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(self, atOffset: range.lowerBound, dataLength: range.count, destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw BlockBufferError(status: status) }
        return data
    }

    /// Copies as many bytes as `destination` holds, from `offset` on.
    func copyDataBytes(atOffset offset: Int = 0, to destination: UnsafeMutableRawBufferPointer) throws(BlockBufferError) {
        guard let baseAddress = destination.baseAddress, destination.count > 0 else {
            return
        }
        let status = CMBlockBufferCopyDataBytes(self, atOffset: offset, dataLength: destination.count, destination: baseAddress)
        guard status == noErr else { throw BlockBufferError(status: status) }
    }

    /// Writes `source` over the bytes from `offset` on.
    func replaceDataBytes(with source: UnsafeRawBufferPointer, atOffset offset: Int = 0) throws(BlockBufferError) {
        guard let baseAddress = source.baseAddress, source.count > 0 else {
            return
        }
        let status = CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: self,
            offsetIntoDestination: offset,
            dataLength: source.count
        )
        guard status == noErr else { throw BlockBufferError(status: status) }
    }

    /// Sets the bytes of `range` to `byte`.
    func fillDataBytes(with byte: UInt8, in range: Range<Int>? = nil) throws(BlockBufferError) {
        let range = range ?? 0..<dataLength
        guard !range.isEmpty else { return }
        let status = CMBlockBufferFillDataBytes(
            with: CChar(bitPattern: byte),
            blockBuffer: self,
            offsetIntoDestination: range.lowerBound,
            dataLength: range.count
        )
        guard status == noErr else { throw BlockBufferError(status: status) }
    }
}

/// Calls a closure when a block buffer no longer uses a memory block it was given.
private final class BlockRelease {
    private let deallocator: (UnsafeMutableRawPointer, Int) -> Void

    init(_ deallocator: @escaping (UnsafeMutableRawPointer, Int) -> Void) {
        self.deallocator = deallocator
    }

    /// The block source of the block: it keeps this release until the block is freed.
    func blockSource() -> CMBlockBufferCustomBlockSource {
        CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { refCon, block, size in
                guard let refCon else { return }
                Unmanaged<BlockRelease>.fromOpaque(refCon).takeRetainedValue().deallocator(block, size)
            },
            refCon: Unmanaged.passRetained(self).toOpaque()
        )
    }

    /// Lets go of the reference the block source kept, when the block buffer didn't take the block.
    func discard() {
        Unmanaged.passUnretained(self).release()
    }
}
