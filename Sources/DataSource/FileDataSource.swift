//
//  FileDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.07.2025.
//

import CoreMedia
import Darwin
import Foundation
import SEPlayerCommon

/// A ``DataSource`` for reading local files.
public final class FileDataSource: DataSource {
    public let components: DataSourceOpaque
    /// The largest chunk the file is read in.
    public let maxChunkSize: Int

    public var isolation: any Actor { queue.playerActor() }

    // The file is read in chunks of whole pages, into memory of a pool, and reads return references into the chunks:
    // no bytes are copied, and many small reads, such as box headers and samples, cost one read of the file. While
    // reading goes forward, chunks grow up to `maxChunkSize` and the next one is read before it is needed. A jump
    // starts over with small chunks. The last chunks are kept, for reads that come back a little, such as peeks.

    private let queue: any Queue
    /// Where the file is read: reads block the thread.
    private let readQueue: any Queue
    private let memoryPool: CMMemoryPool
    /// The first chunk after opening or a jump.
    private let minChunkSize: Int
    private let bypassesSystemCache: Bool

    private var file: OpenFile?
    private var length: Int?
    /// The chunks read last, the newest last.
    private var chunks: [Chunk] = []
    /// The size of the next chunk.
    private var chunkSize: Int
    /// The chunk after the last one, being read before it is needed.
    private var nextChunk: (range: Range<Int>, task: Task<Chunk, any Error>)?
    private var readAhead: ReadAhead?

    /// - Parameters:
    ///   - readQueue: Where the file is read, off the player's queues: reads block the thread.
    ///   - memoryPool: The memory of the chunks; data sources reading files one after another can share it.
    ///   - minChunkSize: The first chunk read, after opening or a jump.
    ///   - maxChunkSize: The largest chunk, while reading goes forward.
    ///   - bypassesSystemCache: Whether the file's pages stay out of the system's file cache, where they would only
    ///     take memory after playback has used them.
    init(
        queue: any Queue,
        readQueue: any Queue,
        memoryPool: CMMemoryPool,
        minChunkSize: Int = 64 * 1024, // 64 KB
        maxChunkSize: Int = 2 * 1024 * 1024, // 2 MB
        bypassesSystemCache: Bool = true
    ) {
        self.queue = queue
        self.readQueue = readQueue
        self.memoryPool = memoryPool
        self.minChunkSize = Self.roundUpToPage(max(minChunkSize, Self.pageSize))
        self.maxChunkSize = max(self.minChunkSize, Self.roundUpToPage(maxChunkSize))
        self.bypassesSystemCache = bypassesSystemCache
        chunkSize = self.minChunkSize
        components = DataSourceOpaque(isNetwork: false)
    }

    deinit {
        nextChunk?.task.cancel()
    }

    public func open(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> Int? {
        guard file == nil else { throw DataSourceError(reason: .alreadyOpened) }

        let file: OpenFile
        do {
            file = try OpenFile(url: dataSpec.url, bypassesSystemCache: bypassesSystemCache)
        } catch {
            SELogger.error(.file, "Opening \(dataSpec.url.lastPathComponent) failed: \(error)")
            throw error
        }
        self.file = file
        length = file.size
        chunks.removeAll()
        chunkSize = minChunkSize
        SELogger.debug(.file, "Opened \(dataSpec.url.lastPathComponent) at \(dataSpec.position), \(file.size) bytes")

        // All of the file is at hand.
        let available = max(0, file.size - dataSpec.position)
        readAhead?.report(availableBytes: available, resourceLength: file.size, holdsToEnd: true)

        return dataSpec.length.map { min($0, available) } ?? available
    }

    public func close(_ isolation: isolated any Actor) async throws {
        nextChunk?.task.cancel()
        nextChunk = nil
        file = nil
        chunks.removeAll()
        length = nil
    }

    public func setReadAhead(_ readAhead: ReadAhead?) {
        self.readAhead = readAhead
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard let file, let length else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        let range = range.clamped(to: range.lowerBound ..< max(range.lowerBound, length))
        defer {
            let available = max(0, length - range.upperBound)
            readAhead?.report(availableBytes: available, resourceLength: length, holdsToEnd: true)
        }
        guard !range.isEmpty else { return try CMBlockBuffer() }

        if let buffer = try reference(range) {
            readNextChunkIfNeeded(after: range, file: file)
            return buffer
        }

        // A read of the chunk being read ahead waits for it.
        if let nextChunk, nextChunk.range.contains(range.lowerBound) {
            self.nextChunk = nil
            if let chunk = try? await nextChunk.task.value {
                keep(chunk)
                growChunkSize()
                if let buffer = try reference(range) {
                    readNextChunkIfNeeded(after: range, file: file)
                    return buffer
                }
            }
        }

        // A read that goes on from the last chunk reads forward, and chunks grow. Anything else is a jump.
        if isSequential(range) {
            growChunkSize()
        } else {
            chunkSize = minChunkSize
            nextChunk?.task.cancel()
            nextChunk = nil
        }

        let start = range.lowerBound / Self.pageSize * Self.pageSize
        let end = min(length, Self.roundUpToPage(max(range.upperBound, start + chunkSize)))
        let chunk = try await readChunk(start ..< end, from: file)
        keep(chunk)
        guard let buffer = try reference(range) else {
            // The file ended sooner than its size said.
            return try reference(range.clamped(to: chunk.range)) ?? CMBlockBuffer()
        }

        readNextChunkIfNeeded(after: range, file: file)
        return buffer
    }
}

private extension FileDataSource {
    /// The bytes of `range` of the file.
    struct Chunk: @unchecked Sendable {
        let range: Range<Int>
        let buffer: CMBlockBuffer
    }

    static let maxKeptChunks = 2
    static let pageSize = Int(vm_page_size)

    static func roundUpToPage(_ value: Int) -> Int {
        (value + pageSize - 1) / pageSize * pageSize
    }

    func isSequential(_ range: Range<Int>) -> Bool {
        guard let lastChunk = chunks.last else { return false }

        let earliestStart = lastChunk.range.upperBound - Self.pageSize
        let latestStart = lastChunk.range.upperBound + chunkSize

        return (earliestStart ... latestStart).contains(range.lowerBound)
    }

    /// The bytes of `range` as references into the chunks, if they hold all of them.
    func reference(_ range: Range<Int>) throws -> CMBlockBuffer? {
        var position = range.lowerBound
        var parts: [(Chunk, Range<Int>)] = []
        while position < range.upperBound {
            guard let chunk = chunks.last(where: { $0.range.contains(position) }) else {
                return nil
            }

            let end = min(range.upperBound, chunk.range.upperBound)
            parts.append((chunk, position ..< end))
            position = end
        }

        let blockBuffer = try CMBlockBuffer()
        for (chunk, part) in parts {
            let start = part.lowerBound - chunk.range.lowerBound
            try blockBuffer.append(bufferReference: chunk.buffer, range: start ..< (start + part.count))
        }

        return blockBuffer
    }

    func keep(_ chunk: Chunk) {
        chunks.removeAll { $0.range == chunk.range }
        chunks.append(chunk)
        if chunks.count > Self.maxKeptChunks {
            chunks.removeFirst(chunks.count - Self.maxKeptChunks)
        }
    }

    func growChunkSize() {
        chunkSize = min(maxChunkSize, chunkSize * 2)
    }

    /// Starts reading the chunk after the last one once reading has gone through half of the last one.
    func readNextChunkIfNeeded(after range: Range<Int>, file: OpenFile) {
        guard nextChunk == nil, let lastChunk = chunks.last, let length else {
            return
        }
        guard lastChunk.range.upperBound < length, chunkSize > minChunkSize else {
            return
        }

        let middleOfLastChunk = lastChunk.range.lowerBound + lastChunk.range.count / 2
        guard range.upperBound >= middleOfLastChunk else { return }

        let nextRange = lastChunk.range.upperBound ..< min(length, lastChunk.range.upperBound + chunkSize)
        SELogger.verbose(.file, "Reading \(nextRange) ahead")
        nextChunk = (nextRange, Task { [self] in try await readChunk(nextRange, from: file) })
    }

    /// Reads `range` of the file on the read queue. The chunk is shorter at the end of the file.
    func readChunk(_ range: Range<Int>, from file: OpenFile) async throws -> Chunk {
        let memoryPool = memoryPool

        return try await withCheckedThrowingContinuation { continuation in
            readQueue.justDispatch {
                let result = Result {
                    try file.readChunk(range, into: memoryPool)
                }
                continuation.resume(with: result)
            }
        }
    }
}

/// A file open for reading, closed when released.
private final class OpenFile: @unchecked Sendable {
    let descriptor: Int32
    let size: Int

    init(url: URL, bypassesSystemCache: Bool) throws {
        // open(2) returns a file descriptor, or -1 on failure with the reason in errno. O_CLOEXEC keeps the
        // descriptor out of processes the app starts.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Self.openError(errno) }

        // fstat(2) fills `status` with the metadata of the open file, of which only the size is used. It returns 0,
        // or -1 on failure with the reason in errno.
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw Self.openError(error)
        }

        if bypassesSystemCache {
            // fcntl(2) with F_NOCACHE turns off the system's file cache for this descriptor: reads go to storage,
            // and their pages aren't kept in memory. A failure only leaves the cache on.
            _ = fcntl(descriptor, F_NOCACHE, 1)
        }

        self.descriptor = descriptor
        size = Int(status.st_size)
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// Reads into `bytes` from `offset` on, until they are full or the file ends.
    ///
    /// - Returns: How many bytes were read.
    func read(into bytes: UnsafeMutableRawBufferPointer, at offset: Int) throws -> Int {
        guard let base = bytes.baseAddress else { return 0 }

        var bytesRead = 0
        while bytesRead < bytes.count {
            // pread(2) reads at an absolute offset without moving the file position, so reads on different threads
            // don't affect each other. It returns the number of bytes read, which may be fewer than asked for,
            // 0 at the end of the file, or -1 on failure with the reason in errno. EINTR means a signal
            // interrupted the call before it read anything, and the call is repeated.
            let result = pread(
                descriptor,
                base + bytesRead,
                bytes.count - bytesRead,
                off_t(offset + bytesRead)
            )

            if result > 0 {
                bytesRead += result
            } else if result == 0 {
                break
            } else if errno != EINTR {
                let error = errno
                let reason = String(cString: strerror(error))
                SELogger.error(.file, "Reading \(bytes.count) bytes at \(offset) failed: \(reason)")
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }

        return bytesRead
    }

    /// Reads `range` into memory of `memoryPool`. The chunk is shorter at the end of the file.
    func readChunk(_ range: Range<Int>, into memoryPool: CMMemoryPool) throws -> FileDataSource.Chunk {
        let buffer = try CMBlockBuffer(
            length: range.count,
            allocator: memoryPool.allocator,
            flags: .assureMemoryNow
        )
        let length = try buffer.withUnsafeMutableBlockBytes { bytes in
            try read(into: bytes, at: range.lowerBound)
        }
        SELogger.verbose(.file, "Read \(range), \(length) bytes")

        return FileDataSource.Chunk(range: range.lowerBound ..< (range.lowerBound + length), buffer: buffer)
    }

    /// A file that is missing or can't be read stays so.
    private static func openError(_ error: Int32) -> DataSourceError {
        let errorCode: PlaybackErrorCode = switch error {
        case ENOENT: .ioFileNotFound
        case EACCES,
             EPERM: .ioNoPermission
        default: .ioUnspecified
        }
        let cause = POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)

        return DataSourceError(
            reason: .customError(cause),
            message: String(cString: strerror(error)),
            errorCode: errorCode
        )
    }
}
