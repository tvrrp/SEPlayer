//
//  HTTPDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import Foundation
import CoreMedia
import SEPlayerCommon

public final class HTTPDataSource<TransportFactory: HTTPTransportFactory>: DataSource {
    public let components: DataSourceOpaque
    public var isolation: any Actor { queue.playerActor() }

    private let queue: any Queue
    private let dataSpec: DataSpec
    private let fetchExecutor: FetchExecutor
    private let cacheHandler: BlockBufferCacheHandler
    private let transportFactory: TransportFactory

    private var urlResponse: HTTPURLResponse?

    public init(
        queue: any Queue,
        transportFactory: TransportFactory,
        dataSpec: DataSpec,
        blockSize: Int = (Int(getpagesize()) * 25),
        memoryPool: CMMemoryPool = CMMemoryPoolCreate(options: nil),
        _ isolation: isolated any Actor
    ) async throws {
        self.queue = queue
        self.transportFactory = transportFactory
        self.dataSpec = dataSpec
        components = DataSourceOpaque(isNetwork: true)
        fetchExecutor = FetchExecutor(queue: queue, factory: transportFactory)
        cacheHandler = BlockBufferCacheHandler(
            queue: queue,
            blockSize: blockSize,
            memoryPool: memoryPool
        )

        fetchExecutor.delegate = self
        try await open(isolation)
    }

    public func canHandle(new dataSpec: DataSpec, _ isolation: isolated any Actor) -> Bool {
        guard let urlResponse else { return false }

        print("🦃 CAN HANDLE CALLED!!!!")
        return urlResponse.isSharable
    }

    private func open(_ isolation: isolated any Actor) async throws {
        assert(queue.isCurrent())
        let openFetch = fetchExecutor.register(dataSpec: dataSpec)

        try await withTaskCancellationHandler(
            operation: {
                try await openFetch.waitForResult()
                transferInitializing(source: self)
            },
            onCancel: {
                queue.async { self.fetchExecutor.cancel(fetch: openFetch) }
            },
            isolation: isolation
        )
    }

    public func close(_ isolation: isolated any Actor) async {
        assert(queue.isCurrent())
        urlResponse = nil
        fetchExecutor.cancelAll()
        cacheHandler.clear()
    }

    public func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        assert(queue.isCurrent())
        return urlResponse
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        assert(queue.isCurrent())
        await Task.yield()
        if let loadedBlockBuffer = try cacheHandler.read(range) {
            return loadedBlockBuffer
        }

        let readFetch = fetchExecutor.register(
            dataSpec: dataSpec
                .buildUpon()
                .setPosition(range.lowerBound)
                .setLength(range.count)
                .build()
        )

        try await withTaskCancellationHandler(
            operation: {
                try await readFetch.waitForResult()
            },
            onCancel: {
                queue.async { self.fetchExecutor.cancel(fetch: readFetch) }
            },
            isolation: isolation
        )

        guard let blockBuffer = try cacheHandler.read(range) else {
            return nil
        }

        return blockBuffer
    }
}

extension HTTPDataSource: FetchExecutorDelegate {
    public func runEventStream(_ stream: AsyncStream<TransportStatus>, fetchId: UUID) {
        Task {
            await queue.playerActor().run { _ in
                for await status in stream {
                    fetchExecutor.recordStatusChange(fetchID: fetchId, status: status)
                }
            }
        }
    }

    public func runSessionStream(_ stream: AsyncStream<TransportEvent>, fetchId: UUID) {
        Task {
            do {
                try await queue.playerActor().run { _ in
                    for try await event in stream {
                        switch event {
                        case let .responseReceived(response, _):
                            self.urlResponse = response
                        case let .bytesReceived(bytes, offset):
                            try cacheHandler.append(bytes, at: offset)
                            fetchExecutor.recordBytesReceived(fetchID: fetchId, count: bytes.count)
                            await Task.yield()
                        case let .metricsReceived(metrics):
                            transferEnded(source: self, metrics: metrics)
                            continue
                        }
                    }
                }
            } catch {
                fatalError()
            }
        }
    }
}

extension HTTPURLResponse {
    package var contentLength: Int? {
        value(forHeaderKey: "Content-Length")?
            .components(separatedBy: "/").last
            .flatMap(Int.init)
    }

    var isSharable: Bool {
        return true
    }

    private func value(forHeaderKey key: String) -> String? {
        return allHeaderFields
            .first { $0.key.description.caseInsensitiveCompare(key) == .orderedSame }?
            .value as? String
    }
}
