//
//  DiskCacheEntry.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import Darwin
import Foundation
import SEPlayerCommon

/// The stored bytes of one resource in a ``DiskCache``.
final class DiskCacheEntry: @unchecked Sendable {
    struct Metadata: Codable {
        static let currentVersion = 2

        var version = Metadata.currentVersion
        var key: String
        var url: URL
        /// The headers of the first response, as a complete response of the whole resource.
        var headers: [String: String]
        var length: Int
        var blockSize: Int
        /// The block each slot of the data file holds, `nil` for an empty slot.
        var slots: [Int?]
    }

    struct StoredResource {
        let response: HTTPURLResponse
        let length: Int
        let blockSize: Int
    }

    let key: String
    let name: String

    var storedResource: StoredResource? {
        lock.withLock {
            guard let metadata else { return nil }

            let response = HTTPURLResponse(
                url: metadata.url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: metadata.headers
            )
            guard let response else { return nil }

            return StoredResource(
                response: response,
                length: metadata.length,
                blockSize: metadata.blockSize
            )
        }
    }

    // The data file is a sequence of slots, each one block of the memory cache's size. It grows a slot at a time up
    // to the cache's entry limit; then a new block takes the slot of the least recently used one. A slot's block is
    // recorded in the metadata only once its bytes are written, and a reused slot is recorded empty before they are,
    // so a crash never pairs a slot with the wrong block.

    private let cache: DiskCache
    private let lock = UnfairLock()

    // Guarded by `lock`.
    private var metadata: Metadata?
    private var slotOfBlock: [Int: Int] = [:]
    /// The value of `useCounter` when each slot was last written or read.
    private var lastUseOfSlot: [UInt64] = []
    private var useCounter: UInt64 = 0
    private var blocksBeingWritten: Set<Int> = []
    private var slotsBeingWritten: Set<Int> = []
    private var isSaveScheduled = false
    /// Counts the times the stored resource was replaced or dropped, so a write that was started for a previous
    /// one isn't recorded for the current one.
    private var storedResourceVersion = 0

    // Used on the cache's I/O queue only.
    private var fileDescriptor: Int32?

    init(cache: DiskCache, key: String, name: String, metadata: Metadata?) {
        self.cache = cache
        self.key = key
        self.name = name

        guard let metadata else { return }

        self.metadata = metadata
        lastUseOfSlot = Array(repeating: 0, count: metadata.slots.count)
        for (slot, block) in metadata.slots.enumerated() {
            if let block {
                slotOfBlock[block] = slot
            }
        }
    }

    deinit {
        if let fileDescriptor {
            Darwin.close(fileDescriptor)
        }
    }

    // MARK: - Resource

    /// Whether `response` describes the stored version of the resource: the same length, and the same `ETag` or
    /// `Last-Modified` where both have one.
    func matches(_ response: HTTPURLResponse, length: Int?) -> Bool {
        guard let stored = storedResource, stored.length == length else {
            return false
        }

        for field in ["ETag", "Last-Modified"] {
            let newValue = response.value(forHTTPHeaderField: field)
            let storedValue = stored.response.value(forHTTPHeaderField: field)
            if let newValue, let storedValue {
                return newValue == storedValue
            }
        }

        return true
    }

    /// Starts storing the resource that `response` describes, dropping anything stored before.
    func start(response: HTTPURLResponse, url: URL, length: Int, blockSize: Int) {
        let newMetadata = Metadata(
            key: key,
            url: url,
            headers: Self.headersOfWholeResource(from: response, length: length),
            length: length,
            blockSize: blockSize,
            slots: []
        )
        let releasedBytes = lock.withLock { replaceMetadata(with: newMetadata) }
        cache.release(releasedBytes, for: name)

        cache.ioQueue.async { [self] in
            truncateDataFile()
            writeMetadata()
        }

        let lengthInKB = length / 1024
        let blockSizeInKB = blockSize / 1024
        SELogger.debug(.diskCache, "Storing \(url.lastPathComponent): \(lengthInKB) KB in blocks of \(blockSizeInKB) KB")
    }

    /// Drops the stored bytes: the resource changed, or the cache is cleared.
    func invalidate() {
        let releasedBytes = lock.withLock { replaceMetadata(with: nil) }
        cache.release(releasedBytes, for: name)

        cache.ioQueue.async { [self] in
            truncateDataFile()
            try? FileManager.default.removeItem(at: cache.metadataURL(name: name))
        }
    }

    func close() { cache.close(self) }

    func saveMetadata() {
        cache.ioQueue.async { [self] in
            writeMetadata()
        }
    }

    // MARK: - Blocks

    func hasBlock(_ block: Int) -> Bool {
        lock.withLock { slotOfBlock[block] != nil }
    }

    /// The first block from `block` on that isn't stored.
    func endOfBlocks(from block: Int) -> Int {
        lock.withLock {
            var end = block
            while slotOfBlock[end] != nil {
                end += 1
            }

            return end
        }
    }

    /// The first stored block after `block`, if any.
    func nextBlock(after block: Int) -> Int? {
        lock.withLock {
            slotOfBlock.keys
                .filter { $0 > block }
                .min()
        }
    }

    /// Writes a full block of the memory cache, which `memory` holds pinned, and unpins it once written.
    func store(block: Int, memory: BlockMemory, length: Int) {
        let reservation = lock.withLock { reserveSlot(for: block) }
        guard let reservation else {
            memory.unpin()
            return
        }

        cache.ioQueue.async { [self] in
            // A reused slot is recorded empty before other bytes go into it.
            if reservation.evictedBlock != nil {
                writeMetadata()
            }

            let failure = write(
                memory.pointer,
                length: length,
                at: reservation.slot * reservation.blockSize
            )
            memory.unpin()

            lock.withLock {
                finishWriting(block, reservation: reservation, succeeded: failure == nil)
            }
            scheduleSave()

            if let failure {
                SELogger.warning(.diskCache, "Writing block \(block) failed: \(String(cString: strerror(failure)))")
                if failure == ENOSPC || failure == EDQUOT {
                    cache.removeLeastRecentlyUsedEntry()
                }
            } else {
                SELogger.verbose(.diskCache, "Stored block \(block) in slot \(reservation.slot)")
            }
        }
    }

    /// Reads `blocks` on the cache's I/O queue and passes each one, with the offset of its first byte, to `deliver`,
    /// until one is missing or `isCancelled` returns `true`. Then calls `completion`.
    func read(
        blocks: Range<Int>,
        isCancelled: @escaping @Sendable () -> Bool,
        deliver: @escaping @Sendable (Int, DispatchData) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        cache.ioQueue.async { [self] in
            for block in blocks {
                guard !isCancelled(), let data = readBlock(block) else { break }

                deliver(data.offset, data.bytes)
            }

            completion()
        }
    }
}

private extension DiskCacheEntry {
    struct SlotReservation {
        let slot: Int
        let blockSize: Int
        /// The block that gave the slot up, if the slot was in use.
        let evictedBlock: Int?
        let storedResourceVersion: Int
    }

    struct BlockLocation {
        let slot: Int
        let length: Int
        let blockSize: Int
    }

    /// Must be called with the lock held.
    ///
    /// - Returns: The bytes the previous metadata held in the data file.
    func replaceMetadata(with newMetadata: Metadata?) -> Int {
        let releasedBytes = metadata.map { $0.slots.count * $0.blockSize } ?? 0
        metadata = newMetadata
        slotOfBlock.removeAll()
        lastUseOfSlot.removeAll()
        blocksBeingWritten.removeAll()
        slotsBeingWritten.removeAll()
        storedResourceVersion += 1

        return releasedBytes
    }

    /// Picks the slot a new block is written to: an empty one, else a new one while the entry may grow, else the one
    /// of the least recently used block. Must be called with the lock held.
    func reserveSlot(for block: Int) -> SlotReservation? {
        guard let metadata else { return nil }
        guard slotOfBlock[block] == nil, !blocksBeingWritten.contains(block) else {
            return nil
        }

        let slot: Int
        var evictedBlock: Int?

        if let emptySlot = firstEmptySlot(in: metadata) {
            slot = emptySlot
        } else if let newSlot = appendSlot(to: metadata) {
            slot = newSlot
        } else if let leastRecentlyUsedSlot = leastRecentlyUsedSlot(in: metadata) {
            slot = leastRecentlyUsedSlot
            evictedBlock = metadata.slots[slot]
            if let evictedBlock {
                slotOfBlock[evictedBlock] = nil
            }
            self.metadata?.slots[slot] = nil
        } else {
            return nil
        }

        blocksBeingWritten.insert(block)
        slotsBeingWritten.insert(slot)

        return SlotReservation(
            slot: slot,
            blockSize: metadata.blockSize,
            evictedBlock: evictedBlock,
            storedResourceVersion: storedResourceVersion
        )
    }

    func firstEmptySlot(in metadata: Metadata) -> Int? {
        metadata.slots.indices.first { slot in
            metadata.slots[slot] == nil && !slotsBeingWritten.contains(slot)
        }
    }

    /// Must be called with the lock held.
    func appendSlot(to metadata: Metadata) -> Int? {
        let sizeWithNewSlot = (metadata.slots.count + 1) * metadata.blockSize
        guard sizeWithNewSlot <= cache.maxEntrySize else { return nil }
        guard cache.reserve(metadata.blockSize, for: name) else { return nil }

        self.metadata?.slots.append(nil)
        lastUseOfSlot.append(0)

        return metadata.slots.count
    }

    func leastRecentlyUsedSlot(in metadata: Metadata) -> Int? {
        metadata.slots.indices
            .filter { metadata.slots[$0] != nil && !slotsBeingWritten.contains($0) }
            .min { lastUseOfSlot[$0] < lastUseOfSlot[$1] }
    }

    /// Must be called with the lock held.
    func finishWriting(_ block: Int, reservation: SlotReservation, succeeded: Bool) {
        // The stored resource may have been replaced while the bytes were written.
        guard reservation.storedResourceVersion == storedResourceVersion else { return }

        let slot = reservation.slot
        blocksBeingWritten.remove(block)
        slotsBeingWritten.remove(slot)
        guard succeeded, let metadata, metadata.slots.indices.contains(slot) else {
            return
        }

        self.metadata?.slots[slot] = block
        slotOfBlock[block] = slot
        lastUseOfSlot[slot] = nextUse()
    }

    /// Must be called on the cache's I/O queue.
    func readBlock(_ block: Int) -> (offset: Int, bytes: DispatchData)? {
        let location = lock.withLock { locateBlock(block) }
        guard let location, location.length > 0, let descriptor = openDataFile() else {
            return nil
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: location.length, alignment: 16)
        // pread(2) reads at an absolute offset without moving the file position. It returns the number of bytes
        // read, which is short only at the end of the file, or -1 on failure.
        let bytesRead = pread(
            descriptor,
            buffer,
            location.length,
            off_t(location.slot * location.blockSize)
        )
        guard bytesRead == location.length else {
            buffer.deallocate()
            SELogger.warning(.diskCache, "Reading block \(block) failed: dropping it")
            dropBlock(block)
            return nil
        }

        let bytes = DispatchData(
            bytesNoCopy: UnsafeRawBufferPointer(start: buffer, count: location.length),
            deallocator: .custom(nil) { buffer.deallocate() }
        )

        return (block * location.blockSize, bytes)
    }

    /// Must be called with the lock held.
    func locateBlock(_ block: Int) -> BlockLocation? {
        guard let metadata, let slot = slotOfBlock[block] else { return nil }

        lastUseOfSlot[slot] = nextUse()
        let bytesAfterBlockStart = metadata.length - block * metadata.blockSize

        return BlockLocation(
            slot: slot,
            length: min(metadata.blockSize, bytesAfterBlockStart),
            blockSize: metadata.blockSize
        )
    }

    func dropBlock(_ block: Int) {
        lock.withLock {
            guard let slot = slotOfBlock.removeValue(forKey: block) else {
                return
            }

            metadata?.slots[slot] = nil
        }
        scheduleSave()
    }

    func scheduleSave() {
        let wasScheduled = lock.withLock {
            let wasScheduled = isSaveScheduled
            isSaveScheduled = true
            return wasScheduled
        }
        guard !wasScheduled else { return }

        cache.ioQueue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
            lock.withLock { isSaveScheduled = false }
            writeMetadata()
        }
    }

    /// Must be called with the lock held.
    func nextUse() -> UInt64 {
        useCounter += 1
        return useCounter
    }
}

// MARK: - Files, on the cache's I/O queue

private extension DiskCacheEntry {
    func writeMetadata() {
        let metadata = lock.withLock { self.metadata }
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else {
            return
        }

        try? data.write(to: cache.metadataURL(name: name), options: .atomic)
    }

    func openDataFile() -> Int32? {
        if let fileDescriptor {
            return fileDescriptor
        }

        // open(2) returns a descriptor, or -1 on failure. O_CREAT creates the file, readable and writable by the
        // user only (0o600), if it doesn't exist.
        let descriptor = Darwin.open(cache.dataURL(name: name).path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }

        fileDescriptor = descriptor
        return descriptor
    }

    func truncateDataFile() {
        guard let descriptor = openDataFile() else { return }

        // ftruncate(2) sets the size of the file: zero drops its contents.
        _ = ftruncate(descriptor, 0)
    }

    /// - Returns: The `errno` of the failure, or `nil` if all `length` bytes were written.
    func write(_ pointer: UnsafeRawPointer, length: Int, at offset: Int) -> Int32? {
        guard let descriptor = openDataFile() else { return errno }

        // pwrite(2) writes at an absolute offset without moving the file position. It returns the number of bytes
        // written, or -1 on failure with the reason in errno.
        let bytesWritten = pwrite(descriptor, pointer, length, off_t(offset))
        if bytesWritten == length {
            return nil
        }

        return bytesWritten < 0 ? errno : EIO
    }

    static func headersOfWholeResource(from response: HTTPURLResponse, length: Int) -> [String: String] {
        // The response may have answered a range: its headers are stored as if it answered all of the resource.
        let fieldsOfRange = ["content-range", "content-length"]
        var headers: [String: String] = [:]

        for (field, value) in response.allHeaderFields {
            guard let field = field as? String, let value = value as? String else {
                continue
            }
            guard !fieldsOfRange.contains(field.lowercased()) else { continue }

            headers[field] = value
        }
        headers["Content-Length"] = String(length)

        return headers
    }
}
