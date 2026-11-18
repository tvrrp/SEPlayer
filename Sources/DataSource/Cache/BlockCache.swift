//
//  BlockCache.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// An in-memory cache of the loaded bytes of one resource.
///
/// Not thread-safe: its owner guards it.
final class BlockCache {
    let blockSize: Int
    let length: Int?

    /// The bytes of the blocks the cache holds.
    var size: Int { blocks.count * blockSize }

    // The bytes are kept in fixed-size blocks of purgeable memory. A block holds a prefix of its bytes: a load starts
    // at the first byte a block is missing and fills it in order.
    //
    // What the system may purge depends on the block the reads have reached:
    // - Blocks before it were read already. They are volatile and purged first.
    // - Blocks from it on, up to `protectedBlockCount`, are never volatile.
    // - Blocks further ahead are volatile too, the furthest purged first.
    //
    // When the budget is used up, a new block takes the memory of the least recently used block before the reads, or
    // else of the furthest block ahead if the new block is nearer.

    private let budget: CacheBudget
    /// The name of the resource in the logs.
    private let name: String
    private let protectedBlockCount: Int

    private var blocks: [Int: Block] = [:]
    /// The block the reads have reached.
    private var readBlock = 0
    private var useCounter: UInt64 = 0
    private var lastPurgedBlocksCheck: DispatchTime?

    /// - Parameters:
    ///   - length: The length of the resource, if known.
    ///   - budget: The memory this cache shares with the others of its factory.
    init(length: Int?, budget: CacheBudget, name: String = "") {
        self.length = length
        self.budget = budget
        self.name = name

        // Large blocks keep the table of a large resource small. Small blocks keep a small resource small.
        let isLargeResource = (length ?? 0) >= Self.largeResourceLength
        blockSize = isLargeResource ? Self.largeBlockSize : Self.smallBlockSize

        // At most half the budget, so the rest of it can hold what loads further ahead.
        let protectedBytes = min(Self.protectedBytes, budget.limit / 2)
        protectedBlockCount = max(1, (protectedBytes + blockSize - 1) / blockSize)

        SELogger.debug(.cache, "Cache for \(name): \(blockSize / 1024) KB blocks, \(protectedBlockCount) protected")
    }

    deinit {
        removeAll()
    }

    // MARK: - Queries

    /// Where the bytes cached from `offset` on end. `offset` itself if it is not cached.
    func endOfCachedBytes(from offset: Int) -> Int {
        let index = offset / blockSize
        let offsetInBlock = offset - index * blockSize
        guard let block = blocks[index], offsetInBlock < block.filledBytes else {
            return offset
        }

        return firstMissingByte(from: offset)
    }

    /// Where a load that brings the bytes from `offset` on starts: the first byte missing in the block of `offset` or
    /// after it, which can be before `offset`. The length of the resource if nothing is missing.
    func firstMissingByte(from offset: Int) -> Int {
        var index = offset / blockSize

        while true {
            let blockStart = index * blockSize
            let blockLength = self.blockLength(index)
            guard blockLength > 0 else { return length ?? blockStart }
            guard let block = blocks[index] else { return blockStart }

            if block.filledBytes < blockLength {
                return blockStart + block.filledBytes
            }

            index += 1
        }
    }

    /// Where the next cached bytes after the block of `offset` start, if any: a load from `offset` ends there.
    func nextCachedByte(after offset: Int) -> Int? {
        let index = offset / blockSize
        let nextIndex = blocks
            .filter { $0.key > index && $0.value.filledBytes > 0 }
            .map(\.key)
            .min()

        return nextIndex.map { $0 * blockSize }
    }

    func contains(_ range: Range<Int>) -> Bool {
        range.isEmpty || endOfCachedBytes(from: range.lowerBound) >= range.upperBound
    }

    /// Whether `bytes` from `offset` on would be kept if they arrived now, when nothing waits for them.
    func canStore(_ bytes: Int, at offset: Int) -> Bool {
        let index = offset / blockSize
        if isProtected(index) {
            return true
        }

        let neededBlocks = (bytes + blockSize - 1) / blockSize
        let freeBytes = budget.isUnderPressure ? 0 : max(0, budget.limit - budget.usedBytes)

        // Blocks read already give way first, then blocks further ahead than the new ones.
        let blocksBeforeReads = blocks.keys
            .filter { $0 < readBlock }
            .count
        let blocksFurtherAhead = blocks.keys
            .filter { $0 >= readBlock + protectedBlockCount && $0 > index + neededBlocks }
            .count

        return freeBytes / blockSize + blocksBeforeReads + blocksFurtherAhead >= neededBlocks
    }

    // MARK: - Reading

    /// The bytes of `range`, which must not be empty.
    ///
    /// - Returns: `nil` if the cache doesn't hold all of them.
    func read(_ range: Range<Int>) throws -> CMBlockBuffer? {
        assert(!range.isEmpty)
        guard !range.isEmpty, contains(range) else { return nil }

        let firstIndex = range.lowerBound / blockSize
        let lastIndex = (range.upperBound - 1) / blockSize

        // A small read is copied, so that it doesn't keep a whole block pinned.
        if range.count <= Self.smallReadLimit, firstIndex == lastIndex {
            return try copy(range, fromBlock: firstIndex)
        }

        let blockBuffer = try CMBlockBuffer()
        for index in firstIndex ... lastIndex {
            guard let block = blocks[index] else { return nil }

            let blockStart = index * blockSize
            let blockRange = blockStart ..< (blockStart + blockSize)
            let rangeInBlock = range.clamped(to: blockRange)
            let offsetInBlock = rangeInBlock.lowerBound - blockStart

            do {
                try block.memory.append(
                    offsetInBlock ..< (offsetInBlock + rangeInBlock.count),
                    to: blockBuffer
                )
            } catch {
                SELogger.debug(.cache, "The system purged block \(index) of \(name) before a read")
                removeBlock(index)
                return nil
            }

            markUsed(index)
        }

        return blockBuffer
    }

    /// The memory of block `index` and its length, pinned, if the block is full. The caller unpins it once done.
    func pinnedFullBlock(_ index: Int) -> (memory: BlockMemory, length: Int)? {
        let length = blockLength(index)
        guard let block = blocks[index], length > 0, block.filledBytes == length else {
            return nil
        }
        guard block.memory.pin() else {
            removeBlock(index)
            return nil
        }

        return (block.memory, length)
    }

    // MARK: - Writing

    /// Stores `data`, the bytes from `offset` on, after the bytes its blocks hold. Bytes already held are skipped.
    ///
    /// - Parameter mustStore: Whether the bytes at an offset are needed now, so they are stored even past the budget.
    /// - Returns: How many bytes, from the start of `data`, are held now: fewer than all of them when there was no
    ///   memory for the rest.
    func write(_ data: DispatchData, at offset: Int, mustStore: (Int) -> Bool) -> Int {
        var storedBytes = 0

        data.enumerateBytes { bytes, _, stop in
            var remainingBytes = UnsafeRawBufferPointer(bytes)

            while !remainingBytes.isEmpty {
                let position = offset + storedBytes
                let count = writeToBlock(
                    remainingBytes,
                    at: position,
                    mustStore: { mustStore(position) }
                )
                guard let count else {
                    stop = true
                    return
                }

                storedBytes += count
                remainingBytes = UnsafeRawBufferPointer(rebasing: remainingBytes[count...])
            }
        }

        return storedBytes
    }

    // MARK: - Volatility

    /// Sets the position the reads have reached, which decides what the system may purge.
    func setReadPosition(_ offset: Int) {
        let newReadBlock = offset / blockSize
        guard newReadBlock != readBlock else { return }

        SELogger.verbose(.cache, "Reads of \(name) reached block \(newReadBlock), \(blocks.count) blocks held")
        readBlock = newReadBlock
        for index in Array(blocks.keys) {
            updateVolatility(index)
        }
    }

    /// Removes the blocks the system purged.
    ///
    /// The system purges volatile blocks without telling. Until a read finds out, they would count as cached. Asking
    /// costs a system call per volatile block, so this does nothing within `purgedBlocksCheckInterval` of the last
    /// call.
    func removePurgedBlocks() {
        let now = DispatchTime.now()
        if let lastPurgedBlocksCheck, now < lastPurgedBlocksCheck + Self.purgedBlocksCheckInterval {
            return
        }
        lastPurgedBlocksCheck = now

        let purgedBlocks = blocks
            .filter { $0.value.memory.isPurged }
            .map(\.key)
        guard !purgedBlocks.isEmpty else { return }

        purgedBlocks.forEach(removeBlock)
        SELogger.debug(.cache, "The system purged \(purgedBlocks.count) blocks of \(name)")
    }

    func removeAll() {
        for index in Array(blocks.keys) {
            removeBlock(index)
        }
    }
}

private extension BlockCache {
    struct Block {
        let memory: BlockMemory
        /// Bytes loaded from the start of the block.
        var filledBytes: Int
        /// The value of `useCounter` when the block was last written or read.
        var lastUse: UInt64
    }

    static let smallBlockSize = 16 * 1024 // 16 KB
    static let largeBlockSize = 64 * 1024 // 64 KB
    /// Resources from this length on get large blocks.
    static let largeResourceLength = 6 * 1024 * 1024 // 6 MB
    /// How much from the reads on is never volatile, and is loaded even when memory is short.
    static let protectedBytes = 4 * 1024 * 1024 // 4 MB
    /// Reads up to this size within one block are copied.
    static let smallReadLimit = 4 * 1024 // 4 KB
    static let purgedBlocksCheckInterval = DispatchTimeInterval.seconds(1)

    func copy(_ range: Range<Int>, fromBlock index: Int) throws -> CMBlockBuffer? {
        guard let block = blocks[index] else { return nil }
        guard block.memory.pin() else {
            SELogger.debug(.cache, "The system purged block \(index) of \(name) before a read")
            removeBlock(index)
            return nil
        }
        defer { block.memory.unpin() }

        let offsetInBlock = range.lowerBound - index * blockSize
        let source = UnsafeRawBufferPointer(
            start: block.memory.pointer + offsetInBlock,
            count: range.count
        )
        let blockBuffer = try CMBlockBuffer(length: range.count, flags: .assureMemoryNow)
        try blockBuffer.replaceDataBytes(with: source)
        markUsed(index)

        return blockBuffer
    }

    /// Stores the start of `bytes`, the bytes from `position` on, in the block of `position`.
    ///
    /// - Returns: How many of `bytes` the block holds now, or `nil` if it can't take them.
    func writeToBlock(_ bytes: UnsafeRawBufferPointer, at position: Int, mustStore: () -> Bool) -> Int? {
        let index = position / blockSize
        let offsetInBlock = position - index * blockSize
        let blockLength = self.blockLength(index)

        if blocks[index] == nil {
            // A block is filled from its start.
            guard offsetInBlock == 0, blockLength > 0 else { return nil }
            guard allocate(index, mustStore: mustStore()) else { return nil }
        }
        guard var block = blocks[index], let source = bytes.baseAddress else {
            return nil
        }

        if block.filledBytes > offsetInBlock {
            // The block holds these bytes already.
            return min(block.filledBytes - offsetInBlock, bytes.count)
        }

        let count = min(bytes.count, blockLength - offsetInBlock)
        // Bytes after a gap, or past the end of the resource, can't be stored.
        guard block.filledBytes == offsetInBlock, count > 0 else { return nil }
        guard block.memory.pin() else {
            removeBlock(index)
            return nil
        }

        let destination = block.memory.pointer + offsetInBlock
        destination.copyMemory(from: source, byteCount: count)
        block.memory.unpin()

        block.filledBytes += count
        block.lastUse = nextUse()
        blocks[index] = block

        if block.filledBytes == blockLength {
            updateVolatility(index)
        }

        return count
    }

    func blockLength(_ index: Int) -> Int {
        guard let length else { return blockSize }

        return min(blockSize, length - index * blockSize)
    }

    func isProtected(_ index: Int) -> Bool {
        index >= readBlock && index < readBlock + protectedBlockCount
    }

    /// Gives block `index` memory: new memory within the budget, or the memory of another block, or, for a block
    /// that is needed now, new memory past the budget.
    func allocate(_ index: Int, mustStore: Bool) -> Bool {
        let isRequired = mustStore || isProtected(index)
        let memory = makeMemoryWithinBudget(isRequired: isRequired)
            ?? takeMemoryOfAnotherBlock(for: index, isRequired: isRequired)
            ?? makeMemoryPastBudget(for: index, isRequired: isRequired)
        guard let memory else {
            SELogger.verbose(.cache, "No memory for block \(index) of \(name)")
            return false
        }

        blocks[index] = Block(memory: memory, filledBytes: 0, lastUse: nextUse())
        return true
    }

    func makeMemoryWithinBudget(isRequired: Bool) -> BlockMemory? {
        guard isRequired || !budget.isUnderPressure else { return nil }
        guard budget.reserve(blockSize) else { return nil }

        return makeMemory()
    }

    func takeMemoryOfAnotherBlock(for index: Int, isRequired: Bool) -> BlockMemory? {
        guard let evictedIndex = blockToEvict(for: index) else { return nil }
        guard let evictedBlock = blocks.removeValue(forKey: evictedIndex) else {
            return nil
        }

        SELogger.verbose(.cache, "Block \(index) of \(name) takes the memory of block \(evictedIndex)")

        guard evictedBlock.memory.isPinned else {
            // The contents of the memory don't matter, only that it isn't purged while it is filled.
            _ = evictedBlock.memory.setVolatility(nil)
            return evictedBlock.memory
        }

        // Block buffers still read the memory and keep it, so the new block gets memory of its own.
        budget.release(blockSize)
        guard budget.reserve(blockSize, force: isRequired) else { return nil }

        return makeMemory()
    }

    func makeMemoryPastBudget(for index: Int, isRequired: Bool) -> BlockMemory? {
        guard isRequired, budget.reserve(blockSize, force: true) else {
            return nil
        }

        SELogger.debug(.cache, "Block \(index) of \(name) is kept past the budget: a read needs it")
        return makeMemory()
    }

    /// Memory for a block whose budget is reserved. The reservation is returned if there is none.
    func makeMemory() -> BlockMemory? {
        guard let memory = BlockMemory(size: blockSize) else {
            SELogger.error(.cache, "Allocating a block of \(blockSize) bytes failed")
            budget.release(blockSize)
            return nil
        }

        return memory
    }

    /// The block whose memory a new block at `index` takes when the budget is used up.
    func blockToEvict(for index: Int) -> Int? {
        let leastRecentlyUsedBeforeReads = blocks
            .filter { $0.key < readBlock && $0.key != index }
            .min { $0.value.lastUse < $1.value.lastUse }?
            .key
        if let leastRecentlyUsedBeforeReads {
            return leastRecentlyUsedBeforeReads
        }

        let furthestAhead = blocks.keys
            .filter { $0 >= readBlock + protectedBlockCount }
            .max()
        if let furthestAhead, furthestAhead > index {
            return furthestAhead
        }

        return nil
    }

    /// Makes a full block volatile, or not, as its place relative to the reads says. A block being filled is never
    /// volatile.
    func updateVolatility(_ index: Int) {
        guard let block = blocks[index] else { return }

        let order: PurgeableMemory.Order? = if block.filledBytes < blockLength(index) || isProtected(index) {
            nil
        } else if index < readBlock {
            .early
        } else {
            .late
        }

        let isIntact = block.memory.setVolatility(order)
        if !isIntact {
            SELogger.debug(.cache, "The system purged block \(index) of \(name)")
            removeBlock(index)
        }
    }

    func removeBlock(_ index: Int) {
        guard blocks.removeValue(forKey: index) != nil else { return }

        budget.release(blockSize)
    }

    func markUsed(_ index: Int) { blocks[index]?.lastUse = nextUse() }

    func nextUse() -> UInt64 {
        useCounter += 1
        return useCounter
    }
}
