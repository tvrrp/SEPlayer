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
        assert(queue.isCurrent())
        return blocks.reduce(into: 0) { $0 + $1.byteRange.count }
    }

    public var availableDataRanges: [Range<Int>] {
        assert(queue.isCurrent())
        return blocks.map { $0.filledRange }
    }

    private let queue: Queue
    private let blockSize: Int
    private let memoryPool: CMMemoryPool
    private let allocator: CFAllocator

    private var blocks: [Block] = []

    public init(
        queue: Queue,
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
            if block.filledRange.contains(range) {
                let low = range.lowerBound - block.byteRange.lowerBound
                return try CMBlockBuffer(bufferReference: block.buffer[low..<(low + range.count)])
            }
        }

        return nil
    }

    public func append(_ data: Data, at offset: Int) throws {
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

    private func extend(_ block: Block, with data: Data, blockOffset: inout Int, position: inout Int, endOffset: Int) throws {
        // Don't grow this block's valid bytes into another block's territory.
        let writeCeiling = nextBlockLowerBound(after: block).map { min(endOffset, $0) } ?? endOffset
        let remainingNow = writeCeiling - blockOffset
        guard remainingNow > 0 else { throw IOError(message: nil, cause: nil) }

        if block.freeCapacity < remainingNow {
            try block.appendBuffer(
                CMBlockBuffer(
                    length: max(remainingNow, blockSize),
                    allocator: allocator,
                    flags: .assureMemoryNow
                )
            )
        }

        let writeStart = blockOffset - block.byteRange.lowerBound
        try data[position..<(position + remainingNow)].withUnsafeBytes {
            try block.buffer[writeStart...].replaceDataBytes(with: $0)
        }

        block.filledBytes += remainingNow
        blockOffset += remainingNow
        position += remainingNow
    }

    private func createBlock(at blockOffset: inout Int, position: inout Int, endOffset: Int, data: Data) throws {
        let writeCeiling = nextBlockLowerBound(after: blockOffset).map { min(endOffset, $0) } ?? endOffset
        let remainingNow = writeCeiling - blockOffset
        guard remainingNow > 0 else { throw IOError(message: nil, cause: nil) }

        let blockBuffer = try CMBlockBuffer(
            length: max(remainingNow, blockSize),
            allocator: allocator,
            flags: .assureMemoryNow
        )

        try data[position..<(position + remainingNow)].withUnsafeBytes {
            try blockBuffer.replaceDataBytes(with: $0)
        }

        let block = Block(
            offsetInData: blockOffset,
            filledBytes: remainingNow,
            buffer: blockBuffer
        )

        if let insertIdx = blocks.firstIndex { $0.byteRange.lowerBound > blockOffset } {
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

            try last.buffer.append(bufferReference: block.buffer)
            last.filledBytes += block.filledBytes
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
            self.byteRange = offsetInData..<buffer.dataLength
            self.filledBytes = filledBytes
            self.buffer = buffer
        }

        func appendBuffer(_ blockBuffer: CMBlockBuffer) throws {
            try buffer.append(bufferReference: blockBuffer)
            byteRange = byteRange.lowerBound..<(byteRange.upperBound + blockBuffer.dataLength)
        }
    }
}
