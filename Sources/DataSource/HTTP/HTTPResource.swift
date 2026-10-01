//
//  HTTPResource.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// Everything the readers of one URL share: the downloaded bytes, the running downloads, and the
/// reads waiting for bytes.
///
/// - A read is answered from the cache. On a miss it waits for a running download that reaches the
///   first missing byte sooner than a new request would answer, or starts a new download there.
///   Requests share one HTTP/2 connection, and a new one waits behind the bytes still arriving for
///   a cancelled one, so continuing a download is often faster, e.g. after a short seek forward.
/// - Each reader runs at most one download of its own, so downloads run in parallel only when
///   readers read different parts of the resource.
/// - A download stops when nobody waits on it and it is `maxBytesAhead` past its reader's latest
///   read. The next read continues from the end of the cached bytes.
/// - The download of a removed reader, as on a seek, keeps running for as long as a new request
///   would take to answer, so the next reader can take it over. Starting a new download stops it.
///
/// All state is guarded by `lock`. URLSession callbacks take it on the session queue, so bytes
/// reach the cache without waiting for the player queue. Waiting reads are resumed only after the
/// lock is released: resuming takes the task's own lock, which `Task.cancel()` holds while the
/// read's cancellation handler waits for this one.
final class HTTPResource: @unchecked Sendable {
    /// One consumer of the resource. Its fields are guarded by the resource lock.
    final class Reader {
        weak var dataSource: HTTPDataSource?
        /// The latest read. Downloads and cached bytes are kept around it.
        var range: Range<Int>
        /// The download this reader started, while it runs.
        fileprivate var download: Download?

        init(position: Int) {
            range = position..<position
        }
    }

    /// A download stops once it is this far past the end of its reader's latest read.
    private let maxBytesAhead = 4 << 20
    /// When the cache is over budget, bytes this far behind a reader are still kept, for peeks.
    private let bytesKeptBehind = 1 << 20
    /// Before the speed and the response time are measured, a read waits for a download at most
    /// this far before it, instead of starting a new one.
    private let maxBytesToSkip = 1 << 20
    /// Guess for the response time until one is measured.
    private let defaultResponseTime = 0.5
    /// Above this size, bytes away from every reader are dropped.
    private let cacheBudget = 32 << 20

    private let dataSpec: DataSpec
    private let sessionLoader: any IPlayerSessionLoader
    private let lock = UnfairLock()
    private let cache = BlockBufferCacheHandler()

    private var readers: [Reader] = []
    private var downloads: [Download] = []
    private var waiters: [Waiter] = []
    private var firstResponse: HTTPURLResponse?
    /// Resumptions of waiting reads, run by `unlockAndResume()` once the lock is released.
    private var pendingResumptions: [() -> Void] = []
    private var length: Int?
    /// Seconds from a request to its response, averaged over the requests of this resource.
    private var responseTime: Double?
    /// Bytes per second arriving for this resource, averaged over windows of `speedWindow`.
    private var bytesPerSecond: Double?
    private let speedWindow = 0.25
    private var speedWindowStart: DispatchTime?
    private var speedWindowBytes = 0

    init(dataSpec: DataSpec, sessionLoader: any IPlayerSessionLoader) {
        self.dataSpec = dataSpec
        self.sessionLoader = sessionLoader
    }

    deinit {
        // A running download would otherwise fetch the rest of the file on the shared session.
        downloads.forEach { $0.cancel() }
    }

    var response: HTTPURLResponse? {
        lock.withLock { firstResponse }
    }

    /// Whether `dataSpec` asks for this same resource; only the position may differ.
    func canServe(_ dataSpec: DataSpec) -> Bool {
        self.dataSpec.url == dataSpec.url
            && self.dataSpec.httpMethod == dataSpec.httpMethod
            && self.dataSpec.allHTTPHeaderFields == dataSpec.allHTTPHeaderFields
            && self.dataSpec.key == dataSpec.key
    }

    // MARK: - Readers

    func addReader(at position: Int) -> Reader {
        let reader = Reader(position: position)
        lock.withLock { readers.append(reader) }
        return reader
    }

    /// Cancels the reader's waiting reads and stops its download, unless others wait on it.
    func remove(_ reader: Reader) {
        lock.lock()
        defer { unlockAndResume() }

        readers.removeAll { $0 === reader }

        for waiter in waiters where waiter.reader === reader {
            resume(waiter, throwing: CancellationError())
        }

        if let download = reader.download {
            reader.download = nil
            if !hasWaiters(download) {
                // Kept for the next reader, which usually comes right away, as after a seek.
                download.orphanedAt = .now()
            }
        }
    }

    // MARK: - Reading

    /// Returns the bytes in `range`: fewer at the end of the resource, `nil` past it.
    func read(_ range: Range<Int>, for reader: Reader, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        lock.withLock { reader.range = range }

        while true {
            let cached = try readFromCache(range, for: reader)
            if cached.isAvailable { return cached.buffer }
            try await wait(for: range, reader: reader, isolation)
        }
    }

    /// Reads `range` from the cache. `isAvailable` is false while its bytes are not here yet;
    /// `buffer` is `nil` past the end of the resource.
    private func readFromCache(_ range: Range<Int>, for reader: Reader) throws -> (isAvailable: Bool, buffer: CMBlockBuffer?) {
        lock.lock()
        defer { unlockAndResume() }

        guard isAvailable(range) else { return (false, nil) }

        // A reader landing in cached bytes, as after a short seek, takes over the download that is
        // extending them. Left alone, it would stop, and a new request would be needed later.
        if reader.download == nil {
            let endOfRun = cache.endOfCachedBytes(from: range.lowerBound)
            if let orphan = downloads.first(where: { $0.isOrphaned && $0.position == endOfRun }) {
                adopt(orphan, by: reader)
            }
        }

        let range = clamped(range)
        return (true, range.isEmpty ? nil : try cache.read(range))
    }

    /// Whether a read of `range` can be answered: its bytes are cached, or it is past the end.
    /// Nothing is answered before the first response, which tells the length of the resource.
    private func isAvailable(_ range: Range<Int>) -> Bool {
        firstResponse != nil && cache.contains(clamped(range))
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let end = min(range.upperBound, length ?? .max)
        return range.lowerBound..<max(range.lowerBound, end)
    }

    /// Suspends until the bytes of `range` arrive or the download bringing them stops.
    private func wait(for range: Range<Int>, reader: Reader, _ isolation: isolated any Actor) async throws {
        let waiter = Waiter(range: range, reader: reader)

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation(isolation: isolation) { (continuation: CheckedContinuation<Void, any Error>) in
                    add(waiter, continuation: continuation)
                }
            },
            onCancel: {
                cancel(waiter)
            },
            isolation: isolation
        )
    }

    /// Parks a read until its bytes arrive, making sure a download is bringing them.
    private func add(_ waiter: Waiter, continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        defer { unlockAndResume() }

        if waiter.isCancelled {
            pendingResumptions.append { continuation.resume(throwing: CancellationError()) }
            return
        }

        if isAvailable(waiter.range) {
            pendingResumptions.append { continuation.resume() }
            return
        }

        let firstMissingByte = cache.endOfCachedBytes(from: waiter.range.lowerBound)
        waiter.download = download(reaching: firstMissingByte, for: waiter.reader)
        waiter.continuation = continuation
        waiters.append(waiter)
    }

    private func cancel(_ waiter: Waiter) {
        lock.lock()
        defer { unlockAndResume() }

        waiter.isCancelled = true
        resume(waiter, throwing: CancellationError())
    }

    // MARK: - Downloads

    /// A running download that reaches `offset` sooner than a new request would answer, or a new
    /// one started at `offset`.
    private func download(reaching offset: Int, for reader: Reader) -> Download {
        let running = downloads
            .filter { $0.position <= offset && canReach(offset, $0) }
            .max { $0.position < $1.position }

        if let running {
            if running.isOrphaned {
                adopt(running, by: reader)
            }
            return running
        }

        if let previous = reader.download, !hasWaiters(previous) {
            stop(previous)
        }
        // They would only take bandwidth, and the connection, from the new request.
        for orphan in downloads where orphan.isOrphaned && !hasWaiters(orphan) {
            stop(orphan)
        }

        let download = Download(resource: self, owner: reader, position: offset)
        reader.download = download
        downloads.append(download)
        download.start(
            request: dataSpec.buildUpon()
                .setPosition(offset)
                .setLength(nil)
                .build()
                .createURLRequest(),
            sessionLoader: sessionLoader
        )
        return download
    }

    /// Whether `download` gets to `offset` before a new request would answer.
    private func canReach(_ offset: Int, _ download: Download) -> Bool {
        let bytesToGo = offset - download.position
        guard let bytesPerSecond else { return bytesToGo <= maxBytesToSkip }
        return Double(bytesToGo) / bytesPerSecond <= responseTime ?? defaultResponseTime
    }

    private func adopt(_ download: Download, by reader: Reader) {
        if let previous = reader.download, previous !== download, !hasWaiters(previous) {
            stop(previous)
        }
        download.owner = reader
        download.orphanedAt = nil
        reader.download = download
    }

    /// Cancels `download` and wakes the reads waiting on it: with `error` if it failed, otherwise
    /// to look again, which may start another download.
    private func stop(_ download: Download, error: (any Error)? = nil) {
        download.cancel()
        downloads.removeAll { $0 === download }
        if downloads.isEmpty {
            // Idle time is not download time.
            speedWindowStart = nil
            speedWindowBytes = 0
        }

        if download.owner?.download === download {
            download.owner?.download = nil
        }

        for waiter in waiters where waiter.download === download {
            resume(waiter, throwing: error)
        }
    }

    /// A download is needed while someone waits on it, while its reader still uses it and it is
    /// not too far ahead of that reader, or, without a reader, while a new reader may yet take it.
    private func isNeeded(_ download: Download) -> Bool {
        if hasWaiters(download) { return true }
        if let orphanedAt = download.orphanedAt {
            return seconds(since: orphanedAt) < responseTime ?? defaultResponseTime
        }
        guard let owner = download.owner, owner.download === download else { return false }
        return download.position - owner.range.upperBound < maxBytesAhead
    }

    private func hasWaiters(_ download: Download) -> Bool {
        waiters.contains { $0.download === download }
    }

    private func isRunning(_ download: Download) -> Bool {
        downloads.contains { $0 === download }
    }

    // MARK: - Download events, on the URLSession queue

    fileprivate func download(_ download: Download, didReceive response: URLResponse) {
        lock.lock()
        defer { unlockAndResume() }

        guard isRunning(download) else { return }

        guard let response = response as? HTTPURLResponse else {
            stop(download, error: URLSessionDataSourceError(failedURL: dataSpec.url, errorReason: .cannotParseResponse))
            return
        }

        // Bytes asked for exactly at the end of the resource are answered with 416.
        let isAtEnd = response.statusCode == 416 && response.resourceLength == download.position

        guard (200...299).contains(response.statusCode) || isAtEnd else {
            stop(download, error: URLSessionDataSourceError(failedURL: dataSpec.url, errorReason: .badServerResponse))
            return
        }

        if firstResponse == nil { firstResponse = response }
        if length == nil { length = response.resourceLength }

        let time = seconds(since: download.startTime)
        responseTime = responseTime.map { ($0 + time) / 2 } ?? time

        if isAtEnd {
            stop(download)
            return
        }

        // A server that ignores `Range` answers 200 with the whole body, so the bytes before
        // our position are dropped.
        download.bytesToSkip = response.statusCode == 200 ? download.position : 0
        wakeWaitersWithAvailableBytes()
    }

    fileprivate func download(_ download: Download, didReceive data: DispatchData) {
        lock.lock()
        defer { unlockAndResume() }

        guard isRunning(download) else { return }

        var data = data
        if download.bytesToSkip > 0 {
            let skipped = min(download.bytesToSkip, data.count)
            download.bytesToSkip -= skipped
            data = data.subdata(in: skipped..<data.count)
        }

        cache.append(data, at: download.position)
        download.position += data.count
        measureSpeed(receivedBytes: data.count)
        wakeWaitersWithAvailableBytes()

        if cache.size > cacheBudget {
            cache.removeAll(except: readers.map {
                ($0.range.lowerBound - bytesKeptBehind)..<($0.range.upperBound + maxBytesAhead)
            })
        }

        // Stop when the next bytes are cached already, or when nobody needs them for now.
        let hasReachedCachedBytes = cache.endOfCachedBytes(from: download.position) > download.position
        if hasReachedCachedBytes || !isNeeded(download) {
            stop(download)
        }
    }

    fileprivate func download(_ download: Download, didFinishWith error: (any Error)?) {
        lock.lock()
        defer { unlockAndResume() }

        guard isRunning(download) else { return }

        // A body that ends cleanly ends at the end of the resource.
        if error == nil, length == nil {
            length = download.position
        }
        stop(download, error: error)
    }

    fileprivate func download(_ download: Download, didCollect metrics: URLSessionTaskMetrics) {
        // Outside the lock: listeners may call back into the data source.
        guard let dataSource = download.owner?.dataSource else { return }
        dataSource.transferEnded(source: dataSource, metrics: metrics)
    }

    private func measureSpeed(receivedBytes: Int) {
        guard let start = speedWindowStart else {
            // The window opens with the first bytes: time before them is response time.
            speedWindowStart = .now()
            return
        }

        speedWindowBytes += receivedBytes
        let elapsed = seconds(since: start)
        guard elapsed >= speedWindow else { return }

        let speed = Double(speedWindowBytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { ($0 + speed) / 2 } ?? speed
        speedWindowStart = .now()
        speedWindowBytes = 0
    }

    private func seconds(since time: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
    }

    // MARK: - Waiters

    private func wakeWaitersWithAvailableBytes() {
        for waiter in waiters where isAvailable(waiter.range) {
            resume(waiter)
        }
    }

    /// Wakes a waiting read once the lock is released.
    private func resume(_ waiter: Waiter, throwing error: (any Error)? = nil) {
        waiters.removeAll { $0 === waiter }
        guard let continuation = waiter.continuation else { return }
        waiter.continuation = nil

        pendingResumptions.append {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func unlockAndResume() {
        let resumptions = pendingResumptions
        pendingResumptions.removeAll()
        lock.unlock()
        resumptions.forEach { $0() }
    }
}

/// A read waiting for bytes. Guarded by the resource lock.
private final class Waiter: @unchecked Sendable {
    let range: Range<Int>
    let reader: HTTPResource.Reader
    var download: Download?
    var continuation: CheckedContinuation<Void, any Error>?
    var isCancelled = false

    init(range: Range<Int>, reader: HTTPResource.Reader) {
        self.range = range
        self.reader = reader
    }
}

/// One GET request, from `position` to the end of the resource.
private final class Download: PlayerSessionDelegate, @unchecked Sendable {
    /// Offset of the next byte this download delivers. Guarded by the resource lock.
    var position: Int
    /// Bytes to drop from the start of the body. Guarded by the resource lock.
    var bytesToSkip = 0
    /// The reader this download reads for. Guarded by the resource lock.
    weak var owner: HTTPResource.Reader?
    /// When its reader went away, while no other reader has taken it. Guarded by the resource lock.
    var orphanedAt: DispatchTime?
    private(set) var startTime = DispatchTime.now()

    var isOrphaned: Bool { orphanedAt != nil }

    private weak var resource: HTTPResource?
    private var task: URLSessionDataTask?

    init(resource: HTTPResource, owner: HTTPResource.Reader, position: Int) {
        self.resource = resource
        self.owner = owner
        self.position = position
    }

    func start(request: URLRequest, sessionLoader: any IPlayerSessionLoader) {
        startTime = .now()
        task = sessionLoader.createTask(request: request, delegate: self)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func didRecieveResponse(
        _ response: URLResponse,
        task: URLSessionTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
        resource?.download(self, didReceive: response)
    }

    func didReciveBuffer(_ buffer: DispatchData, task: URLSessionTask) {
        resource?.download(self, didReceive: buffer)
    }

    func didFinishTask(_ task: URLSessionTask, error: (any Error)?) {
        resource?.download(self, didFinishWith: error.map { URLSessionDataSourceError(error: $0 as NSError) })
    }

    func didFinishCollectingMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        resource?.download(self, didCollect: metrics)
    }
}

extension HTTPURLResponse {
    /// Size of the whole resource. A partial response has it in `Content-Range`
    /// (`bytes 0-99/1000`), a full one in `Content-Length`.
    var resourceLength: Int? {
        if let contentRange = value(forHTTPHeaderField: "Content-Range") {
            return contentRange.split(separator: "/").last.flatMap { Int($0) }
        }

        guard statusCode == 200, expectedContentLength >= 0 else { return nil }
        return Int(expectedContentLength)
    }
}
