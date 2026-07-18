//
//  HTTPDataSource2.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import Foundation
import CoreMedia
import SEPlayerCommon


public final class HTTPDataSource2<TransportFactory: HTTPTransportFactory>: DataSource2 {
    var url: URL? { urlResponse?.url }
    public var urlResponse: HTTPURLResponse?

    private let queue: any Queue
    private let fetchArbiter: FetchArbiter
    private let fetchExecutor: FetchExecutor
    private let cacheHandler: BlockBufferCacheHandler
    private let transportFactory: TransportFactory

    private var currentDataSpec: DataSpec?

    public init(
        queue: any Queue,
        transportFactory: TransportFactory,
        blockSize: Int = (Int(getpagesize()) * 25),
        memoryPool: CMMemoryPool = CMMemoryPoolCreate(options: nil)
    ) {
        self.queue = queue
        self.transportFactory = transportFactory
        fetchArbiter = FetchArbiter()
        fetchExecutor = FetchExecutor(queue: queue, factory: transportFactory)
        cacheHandler = BlockBufferCacheHandler(
            queue: queue,
            blockSize: blockSize,
            memoryPool: memoryPool
        )
    }

    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int? {
        assert(queue.isCurrent())
        if let currentDataSpec {
            if currentDataSpec != dataSpec {
                throw DataSourceError(reason: .alreadyOpened)
            } else {
                return urlResponse?.contentLength2
            }
        }

        currentDataSpec = dataSpec
        let openFetch = fetchExecutor.register(dataSpec: dataSpec, transportDelegate: self)

        return try await withTaskCancellationHandler(
            operation: {
                try await openFetch.waitForResult()
                return urlResponse?.contentLength2
            },
            onCancel: {
                queue.async { self.fetchExecutor.cancel(fetch: openFetch) }
            },
            isolation: queue.playerActor()
        )
    }

    public func close(isolation: isolated any Actor) async {
        assert(queue.isCurrent())
        urlResponse = nil
        currentDataSpec = nil
        fetchExecutor.cancelAll()
    }

    public func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        assert(queue.isCurrent())
        guard let currentDataSpec else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        if let loadedBlockBuffer = try cacheHandler.read(range) {
            return loadedBlockBuffer
        }

        let readFetch = fetchExecutor.register(
            dataSpec: currentDataSpec
                .buildUpon()
                .setPosition(range.lowerBound)
                .setLength(range.count)
                .build()
            ,
            transportDelegate: self
        )

        try await withTaskCancellationHandler(
            operation: {
                try await readFetch.waitForResult()
            },
            onCancel: {
                queue.async { self.fetchExecutor.cancel(fetch: readFetch) }
            },
            isolation: queue.playerActor()
        )

        guard let blockBuffer = try cacheHandler.read(range) else {
            throw EndOfFileError()
        }

        return blockBuffer
    }
}

extension HTTPDataSource2: TransportEventDelegate {
    public func transport(_ transport: any HTTPTransport, didChange status: TransportStatus) {
        assert(queue.isCurrent())
        fetchExecutor.recordStatusChange(fetchID: transport.rangeID, status: status)
    }

    public func transport(_ transport: any HTTPTransport, didRecieve response: HTTPURLResponse, contentLength: Int?) {
        assert(queue.isCurrent())
        urlResponse = urlResponse ?? response
//        fetchExecutor.
    }

    public func transport(_ transport: any HTTPTransport, didRecieve bytes: DispatchData, offset: Int) {
        assert(queue.isCurrent())
        do {
            try cacheHandler.append(bytes, at: offset)
            fetchExecutor.recordBytesReceived(fetchID: transport.rangeID, count: bytes.count)
        } catch {
            fatalError()
        }
    }

    public func transport(_ transport: any HTTPTransport, didRecieve metrics: URLSessionTaskMetrics) {
        assert(queue.isCurrent())
    }
}

struct FetchArbiter {
    private var fetches = [Range<Int>]()

    func register(executor range: Range<Int>) {

    }

    func canAttach(reading range: Range<Int>) -> Bool {
        guard !fetches.isEmpty else {
            return false
        }

        return false
    }
}
