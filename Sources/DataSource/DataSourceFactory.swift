//
//  DataSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// A factory of ``DataSource`` instances.
public protocol DataSourceFactory {
    /// Creates a data source that `transferListener` is added to before its first request.
    func createDataSource(transferListener: TransferListener?) -> any DataSource
    /// Opens a connection to the host of `url` ahead of the requests that need it. Does nothing in factories that
    /// make no network requests.
    func preconnect(to url: URL)
}

public extension DataSourceFactory {
    func createDataSource() -> any DataSource {
        createDataSource(transferListener: nil)
    }

    func preconnect(to url: URL) {}
}

/// A ``DataSourceFactory`` whose data sources read local files and HTTP resources.
///
/// The data sources of one factory share an in-memory cache of the HTTP bytes they load, and optionally a
/// ``DiskCache``.
public final class DefaultDataSourceFactory<NetworkLoader: IPlayerSessionLoader>: DataSourceFactory {
    private let syncActor: PlayerActor
    private let baseDataSourceFactory: (any DataSourceFactory)?
    private let resourcePool: HTTPResourcePool
    private let fileReadQueue: any Queue
    private let fileMemoryPool: CMMemoryPool
    private let networkLoader: NetworkLoader

    /// - Parameters:
    ///   - cacheSize: The memory the downloaded bytes of all resources may take. Bytes a read waits for are kept
    ///     beyond it.
    ///   - diskCache: Where to keep the bytes of resources that don't change on storage, or `nil` for nowhere.
    ///   - fileReadQueue: Where local files are read, off the player's queues; `nil` for one of the factory's own.
    ///   - fileMemoryPool: The memory local files are read into; `nil` for one of the factory's own. Factories can
    ///     share both.
    public init(
        syncActor: PlayerActor,
        networkLoader: NetworkLoader,
        baseDataSourceFactory: (any DataSourceFactory)? = nil,
        cacheSize: Int = 32 * 1024 * 1024, // 32 MB
        diskCache: DiskCache? = nil,
        fileReadQueue: (any Queue)? = nil,
        fileMemoryPool: CMMemoryPool? = nil
    ) {
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.baseDataSourceFactory = baseDataSourceFactory
        self.fileReadQueue = fileReadQueue ?? SignalQueue(name: "com.seplayer.file", qos: .userInitiated)
        self.fileMemoryPool = fileMemoryPool ?? CMMemoryPool()
        resourcePool = HTTPResourcePool(
            sessionLoader: networkLoader,
            budget: CacheBudget(limit: cacheSize),
            diskCache: diskCache
        )
    }

    public func preconnect(to url: URL) {
        if let baseDataSourceFactory {
            baseDataSourceFactory.preconnect(to: url)
        } else {
            networkLoader.preconnect(to: url)
        }
    }

    public func createDataSource(transferListener: TransferListener?) -> any DataSource {
        if let baseDataSourceFactory {
            return baseDataSourceFactory.createDataSource(transferListener: transferListener)
        }

        let queue = syncActor.executor.queue
        return DefaultDataSource(
            queue: queue,
            transferListener: transferListener,
            makeFileDataSource: { [fileReadQueue, fileMemoryPool] in
                FileDataSource(queue: queue, readQueue: fileReadQueue, memoryPool: fileMemoryPool)
            },
            makeHTTPDataSource: { [resourcePool] transferListener in
                HTTPDataSource(
                    queue: queue,
                    transferListener: transferListener,
                    resourceProvider: resourcePool.resource(for:)
                )
            }
        )
    }
}

/// The HTTP resources the data sources of one factory read.
final class HTTPResourcePool: @unchecked Sendable {
    // A resource whose data spec has `keepLoadedBytes` stays after its data sources close. The ones nobody reads are
    // dropped, the least recently used first, when the bytes don't fit the budget or too many are kept. Other
    // resources are dropped as soon as nobody reads them.

    private let sessionLoader: any IPlayerSessionLoader
    private let budget: CacheBudget
    private let diskCache: DiskCache?
    private let lock = UnfairLock()

    /// The least recently used first. Guarded by `lock`.
    private var resources: [HTTPResource] = []

    init(sessionLoader: any IPlayerSessionLoader, budget: CacheBudget, diskCache: DiskCache? = nil) {
        self.sessionLoader = sessionLoader
        self.budget = budget
        self.diskCache = diskCache
    }

    /// The resource a data source reads `dataSpec` from, created if the pool doesn't have it.
    func resource(for dataSpec: DataSpec) -> HTTPResource {
        lock.withLock {
            if let index = resources.firstIndex(where: { $0.canServe(dataSpec) }) {
                let resource = resources.remove(at: index)
                resources.append(resource)
                return resource
            }

            let resource = HTTPResource(
                dataSpec: dataSpec,
                sessionLoader: sessionLoader,
                budget: budget,
                diskCache: diskCache,
                onIdle: { [weak self] _ in self?.dropIdleResources() },
                onCacheFull: { [weak self] in self?.dropIdleResources() }
            )
            resources.append(resource)
            SELogger.verbose(.http, "New resource \(dataSpec.url.lastPathComponent), \(resources.count) in the pool")
            return resource
        }
    }

    private func dropIdleResources() {
        let droppedResources = lock.withLock {
            let idleResources = resources.filter(\.isIdle)
            var usedBytes = budget.usedBytes
            var keptIdleCount = idleResources.count
            var droppedResources: [HTTPResource] = []

            for resource in idleResources {
                let isOverLimits = usedBytes > budget.limit || keptIdleCount > Self.maxIdleResources
                guard !resource.keepsLoadedBytes || isOverLimits else {
                    continue
                }

                usedBytes -= resource.cachedBytes
                keptIdleCount -= 1
                droppedResources.append(resource)
            }

            resources.removeAll { resource in
                droppedResources.contains { $0 === resource }
            }
            if !droppedResources.isEmpty {
                SELogger.debug(.cache, "Dropping \(droppedResources.count) of \(idleResources.count) idle resources")
            }

            return droppedResources
        }

        droppedResources.forEach { $0.discard() }
    }
}

private extension HTTPResourcePool {
    /// At most this many resources nobody reads are kept.
    static let maxIdleResources = 32
}

/// A ``DataSource`` that reads a file or an HTTP resource, depending on the URL of the data spec it opens.
final class DefaultDataSource: DataSource {
    var isolation: any Actor { queue.playerActor() }
    nonisolated var components: DataSourceOpaque { dataSource?.components ?? placeholderComponents }

    private let queue: any Queue
    private let transferListener: TransferListener?
    private let makeFileDataSource: () -> any DataSource
    private let makeHTTPDataSource: (TransferListener?) -> any DataSource
    private let placeholderComponents = DataSourceOpaque(isNetwork: false)
    /// The source of the current or last data spec.
    private var dataSource: (any DataSource)?
    private var fileDataSource: (any DataSource)?
    private var httpDataSource: (any DataSource)?
    private var readAhead: ReadAhead?

    init(
        queue: any Queue,
        transferListener: TransferListener?,
        makeFileDataSource: @escaping () -> any DataSource,
        makeHTTPDataSource: @escaping (TransferListener?) -> any DataSource
    ) {
        self.queue = queue
        self.transferListener = transferListener
        self.makeFileDataSource = makeFileDataSource
        self.makeHTTPDataSource = makeHTTPDataSource
    }

    func open(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> Int? {
        let dataSource: any DataSource
        if dataSpec.url.isFileURL {
            dataSource = fileDataSource ?? makeFileDataSource()
            if fileDataSource == nil, let transferListener {
                dataSource.addTransferListener(transferListener)
            }
            fileDataSource = dataSource
        } else {
            dataSource = httpDataSource ?? makeHTTPDataSource(transferListener)
            httpDataSource = dataSource
        }
        dataSource.setReadAhead(readAhead)

        self.dataSource = dataSource
        return try await dataSource.open(dataSpec: dataSpec, isolation)
    }

    func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard let dataSource else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        return try await dataSource.read(range: range, isolation)
    }

    func close(_ isolation: isolated any Actor) async throws {
        try await dataSource?.close(isolation)
    }

    func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        dataSource?.getURLResponse(isolation)
    }

    func setReadAhead(_ readAhead: ReadAhead?) {
        self.readAhead = readAhead
    }
}
