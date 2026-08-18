//
//  BlockBufferCacheHandler.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import CoreMedia
import SEPlayerCommon

public final class BlockBufferCacheHandler: @unchecked Sendable {
    public var totalBytes: Int {
//        assert(queue.isCurrent())
        return blocks.reduce(into: 0) { $0 += $1.byteRange.count }
    }

    public var availableDataRanges: [Range<Int>] {
//        assert(queue.isCurrent())
        return blocks.map { $0.filledRange }
    }

    private let queue: any Queue
    private let blockSize: Int
    private let memoryPool: CMMemoryPool
    private let allocator: CFAllocator

    private var blocks: [Block] = []

    public init(
        queue: any Queue,
        blockSize: Int = (Int(getpagesize()) * 25),
        memoryPool: CMMemoryPool = CMMemoryPoolCreate(options: nil)
    ) {
        precondition(blockSize > 0)
        self.queue = queue
        self.blockSize = blockSize
        self.memoryPool = memoryPool
        allocator = CMMemoryPoolGetAllocator(memoryPool)
    }

    public func read(_ range: Range<Int>) throws -> CMBlockBuffer? {
        assert(queue.isCurrent())
        for block in blocks {
            guard block.filledRange.contains(range.lowerBound) else { continue }

            let low = range.lowerBound - block.byteRange.lowerBound
            let end = min(range.upperBound, block.filledRange.upperBound)
            let length = end - range.lowerBound

//            print("✅ Did read bytes, range = \(range.lowerBound..<(range.lowerBound + length))")
            return try CMBlockBuffer(bufferReference: block.buffer[low..<(low + length)])
        }

        return nil
    }

    public func append(_ data: DispatchData, at offset: Int) throws {
        assert(queue.isCurrent())
        guard !data.isEmpty else { return }

        var blockOffset = offset
        var position = 0
        let endOffset = offset + data.count

        while blockOffset < endOffset {
            if let block = blocks.first(where: { $0.filledRange.upperBound == blockOffset }) {
                try extend(
                    block,
                    with: data,
                    blockOffset: &blockOffset,
                    position: &position,
                    endOffset: endOffset
                )

                continue
            }

            try createBlock(
                at: &blockOffset,
                position: &position,
                endOffset: endOffset,
                data: data
            )
        }

        try adaptBlockStorageIfNeeded()
    }

    public func dropBelow(_ offset: Int) throws {
        assert(queue.isCurrent())
        blocks.removeAll { $0.availableRange.upperBound <= offset }
    }

    public func clear() {
        assert(queue.isCurrent())
        blocks.removeAll()
    }

    private func extend(_ block: Block, with data: DispatchData, blockOffset: inout Int, position: inout Int, endOffset: Int) throws {
        // Don't grow this block's valid bytes into another block's territory.
        let writeCeiling = nextBlockLowerBound(after: block).map { min(endOffset, $0) } ?? endOffset
        var remainingNow = writeCeiling - blockOffset

        guard remainingNow > 0 else {
            guard let next = blocks.first(where: { $0.filledRange.contains(blockOffset) }) else {
                throw IOError(message: "offset inside next block's capacity but not filled", cause: nil)
            }
            let skip = min(endOffset, next.filledRange.upperBound) - blockOffset
            blockOffset += skip
            position += skip
            return
        }

        if block.freeCapacity < remainingNow {
            try block.appendBuffer(
                CMBlockBuffer(
                    length: max(remainingNow, blockSize),
                    allocator: allocator,
                    flags: .assureMemoryNow
                )
            )
        }

        while remainingNow > 0 {
            let writeStart = blockOffset - block.byteRange.lowerBound

            try block.buffer.withUnsafeMutableBytes(atOffset: writeStart) { bufferPointer in
                let toCopy = min(remainingNow, bufferPointer.count)

                data.copyBytes(to: bufferPointer, from: position..<(position + toCopy))

                remainingNow -= toCopy
                block.filledBytes += toCopy
                blockOffset += toCopy
                position += toCopy
            }
        }
    }

    private func createBlock(at blockOffset: inout Int, position: inout Int, endOffset: Int, data: DispatchData) throws {
        let writeCeiling = nextBlockLowerBound(after: blockOffset).map { min(endOffset, $0) } ?? endOffset
        let remainingNow = writeCeiling - blockOffset

        guard remainingNow > 0 else {
            throw IOError(message: nil, cause: nil)
        }

        let blockBuffer = try createBlockBuffer(
            backededBy: data,
            range: position..<(position + remainingNow)
        )

        let block = Block(
            offsetInData: blockOffset,
            filledBytes: remainingNow,
            buffer: blockBuffer
        )

        if let insertIdx = blocks.firstIndex(where: { $0.byteRange.lowerBound > blockOffset }) {
            blocks.insert(block, at: insertIdx)
        } else {
            blocks.append(block)
        }

        blockOffset += remainingNow
        position += remainingNow
    }

    private func nextBlockLowerBound(after block: Block) -> Int? {
        blocks.first(where: {
            $0.byteRange.lowerBound > block.byteRange.lowerBound
        })?.byteRange.lowerBound
    }

    private func nextBlockLowerBound(after offset: Int) -> Int? {
        blocks.first(where: { $0.byteRange.lowerBound > offset })?.byteRange.lowerBound
    }

    private func adaptBlockStorageIfNeeded() throws {
        blocks = try blocks.reduce(into: [Block]()) { result, block in
            guard let last = result.last,
                  last.filledRange.upperBound == block.filledRange.lowerBound else {
                result.append(block)
                return
            }

            try last.appendBuffer(block.buffer)
            last.filledBytes += block.filledBytes
        }
    }

    private func createBlockBuffer(backededBy data: DispatchData, range: Range<Int>) throws -> CMBlockBuffer {
        let doCopy = if data.count <= 256 * 1024 {
            true
        } else {
            data.regions.count != 1
        }

        switch doCopy {
        case true:
            let result = try data.withContiguousStorageIfAvailable { ptr in
                try CMBlockBuffer(
                    length: range.count,
                    allocator: { _ in
                        return UnsafeMutableRawPointer(mutating: ptr.baseAddress)
                    },
                    deallocator: { _, _ in
                        withExtendedLifetime(data, {})
                    }
                )
            }

            guard let result else { fallthrough }
            return result
        case false:
            let blockBuffer = try CMBlockBuffer(
                length: max(range.count, blockSize),
                allocator: allocator,
                flags: .assureMemoryNow
            )

            try blockBuffer.withUnsafeMutableBytes { bufferPointer in
                data.copyBytes(to: bufferPointer, from: range)
            }

            return blockBuffer
        }
    }
}

private extension BlockBufferCacheHandler {
    final class Block {
        var filledRange: Range<Int> { byteRange.lowerBound..<(byteRange.lowerBound) + filledBytes }
        var availableRange: Range<Int> { filledRange.upperBound..<byteRange.upperBound }
        var freeCapacity: Int { availableRange.count }

        fileprivate var byteRange: Range<Int>
        fileprivate var filledBytes: Int
        fileprivate let buffer: CMBlockBuffer

        init(offsetInData: Int, filledBytes: Int, buffer: CMBlockBuffer) {
            self.byteRange = offsetInData..<(offsetInData + buffer.dataLength)
            self.filledBytes = filledBytes
            self.buffer = buffer
        }

        func appendBuffer(_ blockBuffer: CMBlockBuffer) throws {
            try buffer.append(bufferReference: blockBuffer)
            byteRange = byteRange.lowerBound..<(byteRange.upperBound + blockBuffer.dataLength)
        }
    }
}
