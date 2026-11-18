//
//  HTTPResource.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// The bytes of one HTTP resource, shared by the data sources that read it.
///
/// Loaded bytes are kept in a ``BlockCache``, and on storage when the resource has a ``DiskCache`` entry. A read of
/// bytes that aren't cached waits for a request that brings them.
final class HTTPResource: @unchecked Sendable {
    /// One data source reading the resource. Its properties are guarded by the lock of the resource.
    final class Reader {
        weak var dataSource: HTTPDataSource?
        /// The latest read.
        var range: Range<Int>

        /// Where the requests of this reader end, or `nil` for the end of the resource.
        fileprivate let end: Int?
        fileprivate let readAhead: ReadAhead?
        /// The fetch this reader started or took over, while it runs.
        fileprivate var fetch: Fetch?
        fileprivate var reportedAvailableBytes: Int?
        /// The block of the latest read when the available bytes were last reported.
        fileprivate var reportedAtBlock: Int?

        fileprivate init(position: Int, end: Int?, readAhead: ReadAhead?) {
            range = position..<position
            self.end = end
            self.readAhead = readAhead
        }
    }

    var response: HTTPURLResponse? {
        lock.withLock { firstResponse }
    }

    /// Whether the loaded bytes stay for later data sources once nobody reads the resource.
    var keepsLoadedBytes: Bool { dataSpec.flags.contains(.keepLoadedBytes) }

    /// Whether nobody reads the resource and nothing is being fetched.
    var isIdle: Bool {
        lock.withLock { readers.isEmpty && fetches.isEmpty }
    }

    var cachedBytes: Int {
        lock.withLock { cache?.size ?? 0 }
    }

    // A fetch fills a gap of the cache: it starts at the first missing byte and ends where cached bytes start again,
    // at the end of its reader's data spec, or at the end of the resource. A read of missing bytes waits for a fetch
    // that reaches them soon, or starts one. A fetch stops once nobody needs its bytes.
    //
    // Storage is a second tier under the memory cache: full blocks from the network are written to it, and a gap
    // whose blocks are stored is filled by a fetch that reads the file instead of the network. A stored resource
    // opens without the network, from its stored response. The first response from the network confirms it, or
    // drops what is stored.

    private let dataSpec: DataSpec
    private let sessionLoader: any IPlayerSessionLoader
    private let budget: CacheBudget
    private let lock = UnfairLock()
    /// Called outside the lock.
    private let onIdle: (HTTPResource) -> Void
    /// Called outside the lock, when the cache had no room for received bytes.
    private let onCacheFull: () -> Void

    // Guarded by `lock`.
    /// Created with the first response, which tells the length.
    private var cache: BlockCache?
    private var diskEntry: DiskCacheEntry?
    /// `false` until a response from the network matched what is stored: until then, stored bytes may be of a
    /// version of the resource that changed since.
    private var isStoredResourceConfirmed = true
    /// Whether storage holds, or is taking, the bytes of this version of the resource.
    private var isStoring = false
    private var readers: [Reader] = []
    private var fetches: [Fetch] = []
    private var pendingReads: [PendingRead] = []
    private var firstResponse: HTTPURLResponse?
    private var length: Int?
    /// Continuations and callbacks that must run outside the lock. See `unlockAndRunDeferredActions()`.
    private var deferredActions: [() -> Void] = []
    private var isIdleReported = false
    /// Seconds from a request to its response, averaged over the requests of this resource.
    private var responseTime: Double?
    private var consecutiveTimeouts = 0
    /// Averaged over windows of `speedWindow`.
    private var bytesPerSecond: Double?
    private var speedWindowStart: DispatchTime?
    private var speedWindowBytes = 0

    private var logName: String {
        let name = dataSpec.url.lastPathComponent
        return name.isEmpty ? dataSpec.url.host ?? "resource" : name
    }

    /// Fetches from storage need no connection.
    private var networkFetchCount: Int {
        fetches
            .filter { !$0.isFromStorage }
            .count
    }

    init(
        dataSpec: DataSpec,
        sessionLoader: any IPlayerSessionLoader,
        budget: CacheBudget,
        diskCache: DiskCache? = nil,
        onIdle: @escaping (HTTPResource) -> Void = { _ in },
        onCacheFull: @escaping () -> Void = {}
    ) {
        self.dataSpec = dataSpec
        self.sessionLoader = sessionLoader
        self.budget = budget
        self.onIdle = onIdle
        self.onCacheFull = onCacheFull

        guard let diskCache, DiskCache.canStore(dataSpec) else { return }

        let entry = diskCache.openEntry(for: dataSpec)
        diskEntry = entry
        restoreStoredResource(from: entry)
    }

    deinit {
        // A running request would otherwise load the rest of the resource on the shared session.
        fetches.forEach { $0.cancel() }
        diskEntry?.close()
    }

    /// Whether `dataSpec` asks for this same resource. Only the position and length may differ.
    func canServe(_ dataSpec: DataSpec) -> Bool {
        self.dataSpec.url == dataSpec.url
            && self.dataSpec.httpMethod == dataSpec.httpMethod
            && self.dataSpec.allHTTPHeaderFields == dataSpec.allHTTPHeaderFields
            && self.dataSpec.key == dataSpec.key
    }

    /// Stops the fetches and drops the cached bytes, for a resource nobody reads.
    func discard() {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        let cachedBytes = Self.formatted(bytes: cache?.size ?? 0)
        SELogger.debug(.cache, "Dropping \(logName): \(cachedBytes) cached, \(fetches.count) fetches")

        for fetch in fetches {
            stop(fetch, startsQueuedFetches: false)
        }
        cache?.removeAll()
        diskEntry?.close()
        diskEntry = nil
    }

    /// - Parameters:
    ///   - position: Where the reader starts reading.
    ///   - end: Where the requests of the reader end, or `nil` for the end of the resource.
    func addReader(at position: Int, end: Int?, readAhead: ReadAhead?) -> Reader {
        let reader = Reader(position: position, end: end, readAhead: readAhead)

        lock.lock()
        defer { unlockAndRunDeferredActions() }

        readers.append(reader)
        SELogger.debug(.http, "Reader opens \(logName) at \(position), \(readers.count) readers")

        readAhead?.addObserver(reader) { [weak self, weak reader] in
            guard let self, let reader else { return }

            self.readAheadDidChange(for: reader)
        }
        // What the previous reader of this read-ahead reported, as before a seek, doesn't hold at this position.
        reportAvailableBytes(for: reader)

        return reader
    }

    /// Cancels the pending reads of `reader`. Its fetch goes on for a while, for a reader that opens next.
    func remove(_ reader: Reader) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        readers.removeAll { $0 === reader }
        reader.readAhead?.removeObserver(reader)
        SELogger.debug(.http, "Reader closes \(logName) at \(reader.range.upperBound), \(readers.count) readers left")

        for pendingRead in pendingReads where pendingRead.reader === reader {
            resume(pendingRead, throwing: CancellationError())
        }

        if let fetch = reader.fetch {
            reader.fetch = nil
            if !hasPendingReads(fetch) {
                fetch.readerClosedAt = .now()
            }
        }
        updateCacheReadPosition()
    }

    /// Returns the bytes in `range`: fewer at the end of the resource, `nil` past it.
    func read(_ range: Range<Int>, for reader: Reader, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        lock.withLock {
            reader.range = range
            updateCacheReadPosition()
        }

        while true {
            switch try readFromCache(range, for: reader) {
            case let .bytes(buffer):
                return buffer
            case .endOfResource:
                return nil
            case .notCached:
                try await wait(for: range, reader: reader, isolation)
            }
        }
    }
}

// MARK: - Reading

private extension HTTPResource {
    enum CacheReadResult {
        case bytes(CMBlockBuffer)
        case endOfResource
        case notCached
    }

    func readFromCache(_ range: Range<Int>, for reader: Reader) throws -> CacheReadResult {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        // Nothing is answered before the first response, which tells the length of the resource.
        guard firstResponse != nil, let cache else { return .notCached }

        let range = clampedToLength(range)
        guard !range.isEmpty else { return .endOfResource }
        guard let buffer = try cache.read(range) else { return .notCached }

        // A reader landing in cached bytes, as after a short seek, takes over the fetch that is extending them.
        // Otherwise it would stop, and a new request would be needed later.
        if reader.fetch == nil {
            let endOfCachedBytes = cache.endOfCachedBytes(from: range.lowerBound)
            let fetchWithoutReader = fetches.first { $0.hasNoReader && $0.position == endOfCachedBytes }
            if let fetchWithoutReader {
                assign(fetchWithoutReader, to: reader)
            }
        }

        fetchAhead(for: reader)
        reportAvailableBytes(for: reader, onlyAtNewBlock: true)

        return .bytes(buffer)
    }

    /// Whether a read of `range` can be answered: its bytes are cached, or it is past the end.
    func isAvailable(_ range: Range<Int>) -> Bool {
        guard firstResponse != nil, let cache else { return false }

        return cache.contains(clampedToLength(range))
    }

    func clampedToLength(_ range: Range<Int>) -> Range<Int> {
        let end = min(range.upperBound, length ?? .max)
        return range.lowerBound..<max(range.lowerBound, end)
    }

    /// Suspends until the bytes of `range` arrive or the fetch bringing them stops.
    func wait(for range: Range<Int>, reader: Reader, _ isolation: isolated any Actor) async throws {
        let pendingRead = PendingRead(range: range, reader: reader)

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    add(pendingRead, continuation: continuation)
                }
            },
            onCancel: {
                cancel(pendingRead)
            },
            isolation: isolation
        )
    }

    func add(_ pendingRead: PendingRead, continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        guard !pendingRead.isCancelled else {
            deferredActions.append { continuation.resume(throwing: CancellationError()) }
            return
        }
        guard !isAvailable(pendingRead.range) else {
            deferredActions.append { continuation.resume() }
            return
        }

        // Without a fetch, the read is queued for the next connection that frees up.
        let fetchStart = fetchStart(for: pendingRead.range.lowerBound)
        pendingRead.fetch = fetch(reaching: fetchStart, for: pendingRead.reader)
        pendingRead.continuation = continuation
        pendingReads.append(pendingRead)

        let isQueued = pendingRead.fetch == nil
        SELogger.verbose(.http, "Read \(pendingRead.range) of \(logName) waits\(isQueued ? " for a connection" : "")")
    }

    func cancel(_ pendingRead: PendingRead) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        pendingRead.isCancelled = true
        resume(pendingRead, throwing: CancellationError())
    }

    func resumeAvailableReads() {
        for pendingRead in pendingReads where isAvailable(pendingRead.range) {
            resume(pendingRead)
        }
    }

    /// Resumes a pending read once the lock is released.
    func resume(_ pendingRead: PendingRead, throwing error: (any Error)? = nil) {
        pendingReads.removeAll { $0 === pendingRead }
        guard let continuation = pendingRead.continuation else { return }

        pendingRead.continuation = nil
        deferredActions.append {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func hasPendingReads(_ fetch: Fetch) -> Bool { pendingReads.contains { $0.fetch === fetch } }

    /// Releases the lock, then runs what was deferred while it was held: resuming a continuation, or calling out,
    /// under the lock could re-enter the resource.
    func unlockAndRunDeferredActions() {
        let actions = deferredActions
        deferredActions.removeAll()

        let isIdle = readers.isEmpty && fetches.isEmpty
        let becameIdle = isIdle && !isIdleReported
        isIdleReported = isIdle

        lock.unlock()

        actions.forEach { $0() }
        if becameIdle {
            onIdle(self)
        }
    }
}

// MARK: - Fetches

private extension HTTPResource {
    /// Where a fetch that brings the bytes from `offset` on starts: at the first byte missing in the block of
    /// `offset`, which can be a little before it.
    func fetchStart(for offset: Int) -> Int {
        if let cache {
            return cache.firstMissingByte(from: offset)
        }

        return offset / Self.firstFetchAlignment * Self.firstFetchAlignment
    }

    /// A running fetch that reaches `offset` sooner than a new request would be answered, or a new one started at
    /// `offset`.
    ///
    /// - Returns: `nil` if all connections are busy.
    func fetch(reaching offset: Int, for reader: Reader) -> Fetch? {
        if let runningFetch = runningFetch(reaching: offset) {
            SELogger.verbose(.http, "Waiting for the fetch of \(logName) at \(runningFetch.position) to reach \(offset)")
            if runningFetch.hasNoReader {
                assign(runningFetch, to: reader)
            }

            return runningFetch
        }

        // Fetches nobody waits for would only take bandwidth, and a connection, from the new request.
        if let previousFetch = reader.fetch, !hasPendingReads(previousFetch) {
            stop(previousFetch, startsQueuedFetches: false)
        }
        for fetch in fetches where fetch.hasNoReader && !hasPendingReads(fetch) {
            stop(fetch, startsQueuedFetches: false)
        }

        if networkFetchCount >= Self.maxConnections {
            let fetchNobodyWaitsFor = fetches.first { !$0.isFromStorage && !hasPendingReads($0) }
            guard let fetchNobodyWaitsFor else {
                SELogger.debug(.http, "All connections of \(logName) are busy: the read at \(offset) waits")
                return nil
            }

            stop(fetchNobodyWaitsFor, startsQueuedFetches: false)
        }

        return startFetch(at: offset, for: reader)
    }

    func runningFetch(reaching offset: Int) -> Fetch? {
        fetches
            .filter { $0.position <= offset && canReach(offset, $0) }
            .max { $0.position < $1.position }
    }

    /// Whether `fetch` gets to `offset` before a new request would be answered.
    func canReach(_ offset: Int, _ fetch: Fetch) -> Bool {
        if let end = fetch.end, offset >= end {
            return false
        }

        let bytesToGo = offset - fetch.position
        guard let bytesPerSecond else {
            return bytesToGo <= Self.maxBytesToWaitFor
        }

        return Double(bytesToGo) / bytesPerSecond <= responseTime ?? Self.defaultResponseTime
    }

    /// Starts a fetch at `offset`: from storage if its block is stored there, otherwise from the network.
    func startFetch(at offset: Int, for reader: Reader) -> Fetch {
        if let diskEntry, let cache, diskEntry.hasBlock(offset / cache.blockSize) {
            return startStorageFetch(at: offset, from: diskEntry, blockSize: cache.blockSize, for: reader)
        }

        return startNetworkFetch(at: offset, for: reader)
    }

    func startStorageFetch(at offset: Int, from diskEntry: DiskCacheEntry, blockSize: Int, for reader: Reader) -> Fetch {
        let firstBlock = offset / blockSize
        let blocks = firstBlock..<diskEntry.endOfBlocks(from: firstBlock)
        let start = blocks.lowerBound * blockSize
        let end = min(blocks.upperBound * blockSize, length ?? .max)

        let fetch = Fetch(
            resource: self,
            reader: reader,
            position: start,
            end: end,
            isFromStorage: true
        )
        reader.fetch = fetch
        fetches.append(fetch)

        SELogger.debug(.diskCache, "Reading \(logName) bytes \(start)-\(end - 1) from storage")
        fetch.start(reading: blocks, of: diskEntry)

        return fetch
    }

    func startNetworkFetch(at offset: Int, for reader: Reader) -> Fetch {
        let end = endOfNetworkFetch(from: offset, for: reader)
        let fetch = Fetch(
            resource: self,
            reader: reader,
            position: offset,
            end: end,
            measuresNetwork: !dataSpec.flags.contains(.mightNotUseFullNetworkSpeed)
        )
        reader.fetch = fetch
        fetches.append(fetch)

        var request = dataSpec.buildUpon()
            .setPosition(offset)
            .setLength(end.map { $0 - offset })
            .build()
            .createURLRequest()
        request.timeoutInterval = requestTimeout(base: request.timeoutInterval)

        let lastByte = end.map { String($0 - 1) } ?? ""
        SELogger.info(.http, "GET \(logName) bytes \(offset)-\(lastByte), \(networkFetchCount) connections")
        fetch.start(request: request, sessionLoader: sessionLoader)

        return fetch
    }

    /// Where a request from `offset` ends: where the cache or storage has bytes again, or at the end of the reader's
    /// data spec. `nil` for the end of the resource.
    func endOfNetworkFetch(from offset: Int, for reader: Reader) -> Int? {
        var ends: [Int] = []

        if let cachedBytesStart = cache?.nextCachedByte(after: offset) {
            ends.append(cachedBytesStart)
        }
        if let cache, let storedBlock = diskEntry?.nextBlock(after: offset / cache.blockSize) {
            ends.append(storedBlock * cache.blockSize)
        }
        if let readerEnd = reader.end, readerEnd > offset {
            ends.append(readerEnd)
        }

        return ends.min()
    }

    /// How long a request waits for bytes before it fails: a few times as long as this server takes to answer, and
    /// twice as long after each request that timed out, up to a minute. A slow server would otherwise fail every
    /// request, and every retry, before its first byte.
    func requestTimeout(base: TimeInterval) -> TimeInterval {
        let timeout = max(base, 4 * (responseTime ?? 0))
        let backoff = pow(2, Double(min(consecutiveTimeouts, 3)))

        return min(timeout * backoff, 60)
    }

    func readAheadDidChange(for reader: Reader) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        guard readers.contains(where: { $0 === reader }) else { return }

        fetchAhead(for: reader)
    }

    /// Keeps a fetch going ahead of the reads of a reader with read-ahead enabled, from the first byte it misses.
    func fetchAhead(for reader: Reader) {
        guard let cache, let readAhead = reader.readAhead, readAhead.isEnabled else {
            return
        }
        if let fetch = reader.fetch, isRunning(fetch) {
            return
        }

        let readEnd = reader.range.upperBound
        let start = firstByteToFetch(from: readEnd)
        if let length, start >= length {
            return
        }
        guard start - readEnd < bytesAheadLimit(for: reader) else { return }
        // With the cache full, fetching starts again only once there is room for a whole fetch, not for every block
        // that the reads free.
        guard cache.canStore(Self.minimumFetchBytes, at: start) else { return }
        guard runningFetch(reaching: start) == nil, networkFetchCount < Self.maxConnections else {
            return
        }

        let bytesAhead = Self.formatted(bytes: start - readEnd)
        SELogger.debug(.readAhead, "Fetching \(logName) ahead from \(start), \(bytesAhead) past the reads")
        _ = startFetch(at: start, for: reader)
    }

    /// How far past its latest read a fetch of `reader` goes.
    func bytesAheadLimit(for reader: Reader) -> Int {
        guard let readAhead = reader.readAhead, readAhead.isEnabled else {
            return Self.minimumBytesAhead
        }

        return max(Self.minimumBytesAhead, readAhead.limit)
    }

    func assign(_ fetch: Fetch, to reader: Reader) {
        if let previousFetch = reader.fetch, previousFetch !== fetch, !hasPendingReads(previousFetch) {
            stop(previousFetch, startsQueuedFetches: false)
        }

        SELogger.debug(.http, "A reader takes over the fetch of \(logName) at \(fetch.position)")
        fetch.reader = reader
        fetch.readerClosedAt = nil
        reader.fetch = fetch
    }

    /// Cancels `fetch` and resumes the reads waiting for it: with `error` if it failed, otherwise to look again,
    /// which may start another fetch.
    ///
    /// - Parameter startsQueuedFetches: Whether reads that wait for a connection get the one this frees, and readers
    ///   with read-ahead go on fetching.
    func stop(_ fetch: Fetch, error: (any Error)? = nil, startsQueuedFetches: Bool = true) {
        logStop(of: fetch, error: error)

        fetch.cancel()
        fetches.removeAll { $0 === fetch }
        if fetches.isEmpty {
            // Idle time doesn't count for the speed.
            speedWindowStart = nil
            speedWindowBytes = 0
        }

        if fetch.reader?.fetch === fetch {
            fetch.reader?.fetch = nil
        }

        for pendingRead in pendingReads where pendingRead.fetch === fetch {
            resume(pendingRead, throwing: error)
        }

        guard startsQueuedFetches else { return }

        startQueuedFetches()
        if error == nil {
            readers.forEach { fetchAhead(for: $0) }
        }
    }

    /// Starts fetches for the reads that wait for a connection, while connections are free.
    func startQueuedFetches() {
        let queuedReads = pendingReads.filter { $0.fetch == nil }

        for pendingRead in queuedReads {
            guard !isAvailable(pendingRead.range) else {
                resume(pendingRead)
                continue
            }

            let fetchStart = fetchStart(for: pendingRead.range.lowerBound)
            guard let fetch = fetch(reaching: fetchStart, for: pendingRead.reader) else {
                return
            }

            pendingRead.fetch = fetch
        }
    }

    /// Whether `fetch` should go on: a read waits for it, or its reader isn't far behind it, or its reader closed
    /// too recently for the next reader to have opened.
    func isNeeded(_ fetch: Fetch) -> Bool {
        if hasPendingReads(fetch) {
            return true
        }
        if let readerClosedAt = fetch.readerClosedAt {
            return seconds(since: readerClosedAt) < responseTime ?? Self.defaultResponseTime
        }
        guard let reader = fetch.reader, reader.fetch === fetch else {
            return false
        }

        let bytesAheadOfReads = fetch.position - reader.range.upperBound
        let fetchedBytes = fetch.position - fetch.startPosition

        return bytesAheadOfReads < bytesAheadLimit(for: reader) || fetchedBytes < Self.minimumFetchBytes
    }

    /// Whether the bytes at `offset` are needed now: a read waits for them, or they are just ahead of a read. Those
    /// are stored even past the budget.
    func mustStore(_ offset: Int) -> Bool {
        let isAwaited = pendingReads.contains { $0.range.contains(offset) }
        let isJustAheadOfRead = readers.contains { reader in
            offset >= reader.range.lowerBound && offset < reader.range.upperBound + Self.minimumBytesAhead
        }

        return isAwaited || isJustAheadOfRead
    }

    func isRunning(_ fetch: Fetch) -> Bool { fetches.contains { $0 === fetch } }

    /// Where the bytes held from `offset` on, in memory or on storage, end.
    func endOfHeldBytes(from offset: Int) -> Int {
        guard let cache else { return offset }

        var end = cache.endOfCachedBytes(from: offset)
        guard let diskEntry else { return end }

        while true {
            if let length, end >= length {
                return length
            }

            let block = end / cache.blockSize
            guard diskEntry.hasBlock(block) else { return end }

            let endOfStoredBlocks = diskEntry.endOfBlocks(from: block) * cache.blockSize
            end = cache.endOfCachedBytes(from: min(endOfStoredBlocks, length ?? .max))
        }
    }

    /// The first byte from `offset` on that neither memory nor storage holds.
    func firstByteToFetch(from offset: Int) -> Int {
        guard let cache else { return offset }

        var start = cache.firstMissingByte(from: offset)
        guard let diskEntry else { return start }

        while true {
            if let length, start >= length {
                return start
            }

            let block = start / cache.blockSize
            guard diskEntry.hasBlock(block) else { return start }

            let endOfStoredBlocks = diskEntry.endOfBlocks(from: block) * cache.blockSize
            start = cache.firstMissingByte(from: endOfStoredBlocks)
        }
    }

    /// The reads have reached the earliest of the readers' latest reads: what is before it may be purged first.
    func updateCacheReadPosition() {
        guard let cache, let earliestRead = readers.map(\.range.lowerBound).min() else {
            return
        }

        cache.setReadPosition(earliestRead)
    }

    /// Tells the reader's read-ahead how many bytes are held without a gap after its latest read.
    ///
    /// - Parameter onlyAtNewBlock: Reports only once the reads reach another block, for a report after each read.
    func reportAvailableBytes(for reader: Reader, onlyAtNewBlock: Bool = false) {
        guard let readAhead = reader.readAhead else { return }
        guard let cache else {
            // Before the first response nothing is held.
            if reader.reportedAvailableBytes != 0 {
                reader.reportedAvailableBytes = 0
                deferredActions.append {
                    readAhead.report(availableBytes: 0, resourceLength: nil, holdsToEnd: false)
                }
            }
            return
        }

        // Purged blocks are not held: reported, they would make the buffer jump back and forth.
        cache.removePurgedBlocks()

        let readEnd = reader.range.upperBound
        let block = readEnd / cache.blockSize
        if onlyAtNewBlock, reader.reportedAtBlock == block {
            return
        }

        // Stored bytes count: they need no network.
        let availableBytes = max(0, endOfHeldBytes(from: readEnd) - readEnd)
        let length = length
        let holdsToEnd = length.map { readEnd + availableBytes >= $0 } ?? false

        if let reportedBytes = reader.reportedAvailableBytes {
            let isSmallChange = abs(availableBytes - reportedBytes) < Self.minimumReportedChange
            // Reaching the end is reported whatever the change.
            let isEndReported = !holdsToEnd || availableBytes == reportedBytes
            if isSmallChange, isEndReported {
                return
            }
        }

        reader.reportedAvailableBytes = availableBytes
        reader.reportedAtBlock = block
        deferredActions.append {
            readAhead.report(availableBytes: availableBytes, resourceLength: length, holdsToEnd: holdsToEnd)
        }
    }
}

// MARK: - Fetch events, on the URLSession queue or the disk cache queue

private extension HTTPResource {
    func fetch(_ fetch: Fetch, didReceive response: URLResponse) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        guard isRunning(fetch) else { return }
        guard let response = response as? HTTPURLResponse else {
            let error = URLSessionDataSourceError(failedURL: dataSpec.url, errorReason: .cannotParseResponse)
            stop(fetch, error: error)
            return
        }

        logResponse(response, to: fetch)

        // Bytes asked for exactly at the end of the resource are answered with 416.
        let isAtEnd = response.statusCode == 416 && response.resourceLength == fetch.position

        guard (200...299).contains(response.statusCode) || isAtEnd else {
            // A range past the end of the resource stays so: loading it again can't succeed.
            let cause = response.statusCode == 416
                ? DataSourceError(reason: .positionOutOfRange, errorCode: .ioReadPositionOutOfRange)
                : nil
            let error = InvalidResponseCodeError(response: response, url: dataSpec.url, cause: cause)
            stop(fetch, error: error)
            return
        }

        if firstResponse == nil {
            firstResponse = response
        }
        if length == nil {
            length = response.resourceLength
        }
        if cache == nil {
            cache = BlockCache(length: length, budget: budget, name: logName)
            updateCacheReadPosition()
        }
        guard confirmStoredResource(with: response, fetch: fetch) else {
            return
        }

        let time = seconds(since: fetch.startTime)
        responseTime = responseTime.map { ($0 + time) / 2 } ?? time
        consecutiveTimeouts = 0

        guard !isAtEnd else {
            stop(fetch)
            return
        }

        // A server that ignores `Range` answers 200 with the whole body, so the bytes before the position of the
        // fetch are dropped.
        fetch.bytesToSkip = response.statusCode == 200 ? fetch.position : 0
        resumeAvailableReads()
    }

    func fetch(_ fetch: Fetch, didReceive data: DispatchData) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        guard isRunning(fetch), let cache else { return }

        var data = data
        if fetch.bytesToSkip > 0 {
            let skippedBytes = min(fetch.bytesToSkip, data.count)
            fetch.bytesToSkip -= skippedBytes
            data = data.subdata(in: skippedBytes..<data.count)
        }
        if let end = fetch.end, fetch.position + data.count > end {
            // A server that ignores the end of `Range` sends on into bytes that are cached already.
            data = data.subdata(in: 0..<max(0, end - fetch.position))
        }

        let start = fetch.position
        let storedBytes = cache.write(data, at: start, mustStore: mustStore)
        fetch.position += storedBytes

        if !fetch.isFromStorage {
            measureSpeed(receivedBytes: storedBytes)
            storeFilledBlocks(from: start, to: fetch.position)
        }
        resumeAvailableReads()
        readers.forEach { reportAvailableBytes(for: $0) }

        guard storedBytes == data.count else {
            let usedBytes = Self.formatted(bytes: budget.usedBytes)
            let limit = Self.formatted(bytes: budget.limit)
            SELogger.debug(.cache, "No room for \(logName) at \(fetch.position): \(usedBytes) of \(limit) used")

            // Whoever needs the rest asks again once there is room.
            stop(fetch)
            deferredActions.append(onCacheFull)
            return
        }

        let hasReachedEnd = fetch.end.map { fetch.position >= $0 } ?? false
        let hasReachedCachedBytes = cache.endOfCachedBytes(from: fetch.position) > fetch.position
        if hasReachedEnd || hasReachedCachedBytes || !isNeeded(fetch) {
            stop(fetch)
        }
    }

    func fetch(_ fetch: Fetch, didFinishWith error: (any Error)?) {
        lock.lock()
        defer { unlockAndRunDeferredActions() }

        guard isRunning(fetch) else { return }

        let hasTimedOut = (error as? URLSessionDataSourceError)?.errorReason == .timedOut
        if hasTimedOut, fetch.position == fetch.startPosition {
            consecutiveTimeouts += 1
            SELogger.info(.http, "Request for \(logName) timed out without bytes, \(consecutiveTimeouts) in a row")
        }

        // A body without an end of its own that ends cleanly ends at the end of the resource.
        if error == nil, length == nil, fetch.end == nil {
            length = fetch.position
        }

        stop(fetch, error: error)
    }

    func fetch(_ fetch: Fetch, didCollect metrics: URLSessionTaskMetrics) {
        logConnection(of: metrics)

        // Not under the lock: listeners may call back into the data source.
        guard let dataSource = fetch.reader?.dataSource else { return }

        dataSource.transferEnded(source: dataSource, metrics: metrics)
    }
}

// MARK: - Storage

private extension HTTPResource {
    /// Opens the resource from what storage holds of it: its response, and a cache of its block size.
    func restoreStoredResource(from entry: DiskCacheEntry) {
        guard let storedResource = entry.storedResource else { return }

        let cache = BlockCache(length: storedResource.length, budget: budget, name: logName)
        guard cache.blockSize == storedResource.blockSize else {
            entry.invalidate()
            return
        }

        firstResponse = storedResource.response
        length = storedResource.length
        self.cache = cache
        isStoredResourceConfirmed = false
        isStoring = true

        let storedLength = Self.formatted(bytes: storedResource.length)
        SELogger.info(.diskCache, "Opening \(logName) from storage: \(storedLength)")
    }

    /// Checks the first response from the network against what storage holds, or starts storing the resource.
    ///
    /// - Returns: `false` if the resource changed since it was stored: the reads, which may have had bytes of the
    ///   old version, fail, and loading starts over with the new one.
    func confirmStoredResource(with response: HTTPURLResponse, fetch: Fetch) -> Bool {
        guard let diskEntry else { return true }

        if !isStoredResourceConfirmed {
            isStoredResourceConfirmed = true

            guard !diskEntry.matches(response, length: response.resourceLength) else {
                SELogger.debug(.diskCache, "\(logName) is as stored")
                return true
            }

            dropStoredResource(replacedBy: response)
        }

        guard !isStoring else { return true }
        // Only a resource of a known length is stored.
        guard let length, let cache, (200...299).contains(response.statusCode) else {
            diskEntry.close()
            self.diskEntry = nil
            return true
        }

        diskEntry.start(
            response: response,
            url: dataSpec.url,
            length: length,
            blockSize: cache.blockSize
        )
        isStoring = true

        return isRunning(fetch)
    }

    func dropStoredResource(replacedBy response: HTTPURLResponse) {
        SELogger.warning(.diskCache, "\(logName) changed since it was stored: dropping it")
        diskEntry?.invalidate()
        isStoring = false

        let error = DataSourceError(reason: .resourceChanged, message: "\(logName) changed since it was stored")
        for fetch in fetches {
            stop(fetch, error: error, startsQueuedFetches: false)
        }
        for pendingRead in pendingReads {
            resume(pendingRead, throwing: error)
        }

        cache?.removeAll()
        firstResponse = response
        length = response.resourceLength
        cache = BlockCache(length: length, budget: budget, name: logName)
        updateCacheReadPosition()
    }

    /// Writes the blocks that a network fetch filled to storage.
    func storeFilledBlocks(from start: Int, to end: Int) {
        guard let diskEntry, let cache else { return }
        guard isStoring, isStoredResourceConfirmed, end > start else { return }

        let firstBlock = start / cache.blockSize
        let lastBlock = (end - 1) / cache.blockSize

        for block in firstBlock...lastBlock where !diskEntry.hasBlock(block) {
            guard let (memory, length) = cache.pinnedFullBlock(block) else {
                continue
            }

            diskEntry.store(block: block, memory: memory, length: length)
        }
    }
}

// MARK: - Measurements and logs

private extension HTTPResource {
    func measureSpeed(receivedBytes: Int) {
        guard let speedWindowStart else {
            // The window opens with the first bytes: the time before them is response time.
            speedWindowStart = .now()
            return
        }

        speedWindowBytes += receivedBytes
        let elapsed = seconds(since: speedWindowStart)
        guard elapsed >= Self.speedWindow else { return }

        let speed = Double(speedWindowBytes) / elapsed
        let averageSpeed = bytesPerSecond.map { ($0 + speed) / 2 } ?? speed
        bytesPerSecond = averageSpeed
        self.speedWindowStart = .now()
        speedWindowBytes = 0

        SELogger.verbose(.http, "\(logName) arrives at \(Self.formatted(bytes: Int(averageSpeed)))/s")
    }

    func seconds(since time: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
    }

    func logStop(of fetch: Fetch, error: (any Error)?) {
        let fetchedBytes = Self.formatted(bytes: fetch.position - fetch.startPosition)

        if let error, !(error is CancellationError) {
            SELogger.warning(.http, "Fetch of \(logName) at \(fetch.position) failed after \(fetchedBytes): \(error)")
        } else {
            let duration = Self.formatted(seconds: seconds(since: fetch.startTime))
            SELogger.debug(.http, "Fetch of \(logName) stops at \(fetch.position) after \(fetchedBytes) in \(duration)s")
        }
    }

    func logResponse(_ response: HTTPURLResponse, to fetch: Fetch) {
        guard SELogger.isEnabled(.http, .debug) else { return }

        let duration = Self.formatted(seconds: seconds(since: fetch.startTime))
        let length = response.resourceLength.map(String.init) ?? "unknown"
        SELogger.debug(.http, "Response \(response.statusCode) for \(logName) at \(fetch.position) in \(duration)s, length \(length)")
    }

    func logConnection(of metrics: URLSessionTaskMetrics) {
        guard SELogger.isEnabled(.http, .debug), let transaction = metrics.transactionMetrics.last else {
            return
        }

        let connection = transaction.isReusedConnection ? "reused" : "new"
        let networkProtocol = transaction.networkProtocolName ?? "unknown protocol"
        let connectTime = Self.formatted(
            millisecondsFrom: transaction.connectStartDate,
            to: transaction.connectEndDate
        )
        let tlsTime = Self.formatted(
            millisecondsFrom: transaction.secureConnectionStartDate,
            to: transaction.secureConnectionEndDate
        )
        let firstByteTime = Self.formatted(
            millisecondsFrom: transaction.requestStartDate,
            to: transaction.responseStartDate
        )
        SELogger.debug(.http, "Connection of \(logName): \(connection), \(networkProtocol), connect \(connectTime) ms, TLS \(tlsTime) ms, first byte \(firstByteTime) ms")
    }
}

// MARK: - Constants and helpers

private extension HTTPResource {
    /// Without read-ahead, a fetch stops once it is this far past the end of its reader's latest read.
    static let minimumBytesAhead = 2 * 1024 * 1024 // 2 MB
    /// Before the speed and the response time are measured, a read waits for a fetch at most this far before it,
    /// instead of starting a new one.
    static let maxBytesToWaitFor = 1024 * 1024 // 1 MB
    /// The response time assumed until one is measured, in seconds.
    static let defaultResponseTime = 0.5
    /// At most this many requests run at once: one can read on while another fetches elsewhere, as the `moov` box
    /// at the end of a file. A read needing one more waits until one stops.
    static let maxConnections = 2
    /// The first fetch starts at a multiple of this, so it starts at a block whatever block size the length of the
    /// resource brings.
    static let firstFetchAlignment = 64 * 1024 // 64 KB
    /// Changes of the bytes held ahead of a reader smaller than this aren't reported to its read-ahead.
    static let minimumReportedChange = 64 * 1024 // 64 KB
    /// A fetch goes on for at least this many bytes while its reader is open: loading that stops and starts again
    /// around a buffer level would otherwise send a request for every few bytes.
    static let minimumFetchBytes = 1024 * 1024 // 1 MB
    /// In seconds.
    static let speedWindow = 0.25

    static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func formatted(seconds: Double) -> String { String(format: "%.3f", seconds) }

    static func formatted(millisecondsFrom start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "–" }

        return String(format: "%.0f", end.timeIntervalSince(start) * 1000)
    }
}

/// A read waiting for bytes. Guarded by the lock of the resource.
private final class PendingRead: @unchecked Sendable {
    let range: Range<Int>
    let reader: HTTPResource.Reader

    /// The fetch that brings the bytes, or `nil` while the read is queued for a connection.
    var fetch: Fetch?
    var continuation: CheckedContinuation<Void, any Error>?
    var isCancelled = false

    init(range: Range<Int>, reader: HTTPResource.Reader) {
        self.range = range
        self.reader = reader
    }
}

/// One GET request for a range of the resource, or a read of its stored blocks.
private final class Fetch: PlayerSessionDelegate, @unchecked Sendable {
    /// A fetch from storage takes no connection and reports no transfer.
    let isFromStorage: Bool
    let startPosition: Int
    /// `nil` for the end of the resource.
    let end: Int?

    // Guarded by the lock of the resource.
    /// The offset of the next byte the fetch delivers.
    var position: Int
    /// Bytes to drop from the start of the body, when the server ignored `Range`.
    var bytesToSkip = 0
    weak var reader: HTTPResource.Reader?
    /// Set while the reader of the fetch has closed and no other has taken the fetch over.
    var readerClosedAt: DispatchTime?
    private(set) var startTime = DispatchTime.now()

    var hasNoReader: Bool { readerClosedAt != nil }

    /// The listeners of the data source the fetch was started for, which stay when another reader takes the fetch
    /// over, so all events of a request go to one place. `nil` for a fetch whose timing says nothing of the network.
    private let transferListeners: DataSourceOpaque?
    private let requestId = Fetch.makeRequestId()
    private let lock = UnfairLock()

    private weak var resource: HTTPResource?
    private var task: URLSessionDataTask?
    /// Guarded by `lock`.
    private var hasEnded = false

    init(
        resource: HTTPResource,
        reader: HTTPResource.Reader,
        position: Int,
        end: Int?,
        isFromStorage: Bool = false,
        measuresNetwork: Bool = true
    ) {
        self.resource = resource
        self.reader = reader
        self.position = position
        self.end = end
        self.isFromStorage = isFromStorage
        startPosition = position

        let reportsTransfer = !isFromStorage && measuresNetwork
        transferListeners = reportsTransfer ? reader.dataSource?.components : nil
    }

    func start(request: URLRequest, sessionLoader: any IPlayerSessionLoader) {
        startTime = .now()
        task = sessionLoader.createTask(request: request, delegate: self)
        report(.requestSent)
        task?.resume()
    }

    /// Reads `blocks` of `entry`, and finishes after the last one, or at the first that is gone.
    func start(reading blocks: Range<Int>, of entry: DiskCacheEntry) {
        startTime = .now()
        entry.read(
            blocks: blocks,
            isCancelled: { [weak self] in
                guard let self else { return true }

                return lock.withLock { self.hasEnded }
            },
            deliver: { [weak self] _, data in
                guard let self else { return }

                resource?.fetch(self, didReceive: data)
            },
            completion: { [weak self] in
                guard let self else { return }

                reportEnd()
                resource?.fetch(self, didFinishWith: nil)
            }
        )
    }

    func cancel() {
        task?.cancel()
        // Bytes still in flight reach nobody: for the listeners the request is over.
        reportEnd()
    }

    // MARK: - PlayerSessionDelegate

    func didRecieveResponse(
        _ response: URLResponse,
        task: URLSessionTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)

        let expectedBytes = response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
        report(.responseReceived(expectedBytes: expectedBytes))
        resource?.fetch(self, didReceive: response)
    }

    func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask) {
        let hasEnded = lock.withLock { self.hasEnded }
        if !hasEnded {
            report(.bytesReceived(buffer.count))
        }

        resource?.fetch(self, didReceive: buffer)
    }

    func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        reportEnd()

        let error = error.map { URLSessionDataSourceError(error: $0 as NSError) }
        resource?.fetch(self, didFinishWith: error)
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        resource?.fetch(self, didCollect: metrics)
    }

    private func reportEnd() {
        let hadEnded = lock.withLock {
            let hadEnded = hasEnded
            hasEnded = true
            return hadEnded
        }

        if !hadEnded {
            report(.requestEnded)
        }
    }

    private func report(_ kind: NetworkTransferEvent.Kind) {
        transferListeners?.networkTransfer(NetworkTransferEvent(requestId: requestId, kind: kind))
    }

    private static let requestIdLock = UnfairLock()
    nonisolated(unsafe) private static var lastRequestId: UInt64 = 0

    private static func makeRequestId() -> UInt64 {
        requestIdLock.withLock {
            lastRequestId += 1
            return lastRequestId
        }
    }
}

extension HTTPURLResponse {
    /// The size of the whole resource. A partial response has it in `Content-Range` (`bytes 0-99/1000`), a full one
    /// in `Content-Length`.
    var resourceLength: Int? {
        if let contentRange = value(forHTTPHeaderField: "Content-Range") {
            return contentRange
                .split(separator: "/")
                .last
                .flatMap { Int($0) }
        }
        guard statusCode == 200, expectedContentLength >= 0 else { return nil }

        return Int(expectedContentLength)
    }
}
