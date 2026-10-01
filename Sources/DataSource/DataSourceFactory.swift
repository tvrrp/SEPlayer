//
//  DataSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import CoreMedia
import Foundation
import SEPlayerCommon

public protocol DataSourceFactory {
    func createDataSource(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> any DataSource
}

public final class DefaultDataSourceFactory<NetworkLoader: IPlayerSessionLoader>: DataSourceFactory {
    private let segmentLength: Int?
    private let syncActor: PlayerActor
    private let networkLoader: NetworkLoader
    private let baseDataSourceFactory: (any DataSourceFactory)?

    /// Resources in use by some data source. Data sources of the same URL share one.
    private let resources = NSHashTable<HTTPResource>.weakObjects()

    public init(
        segmentLength: Int? = nil,
        syncActor: PlayerActor,
        networkLoader: NetworkLoader,
        baseDataSourceFactory: (any DataSourceFactory)? = nil
    ) {
        self.segmentLength = segmentLength
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.baseDataSourceFactory = baseDataSourceFactory
    }

    public func createDataSource(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> any DataSource {
        if let baseDataSourceFactory {
            return try await baseDataSourceFactory.createDataSource(dataSpec: dataSpec, isolation)
        }

        let queue = syncActor.executor.queue

        if dataSpec.url.isFileURL {
            return try await FileDataSource(queue: queue, dataSpec: dataSpec, isolation)
        }

        return try await HTTPDataSource(
            queue: queue,
            resource: resource(for: dataSpec),
            position: dataSpec.position,
            isolation
        )
    }

    private func resource(for dataSpec: DataSpec) -> HTTPResource {
        if let resource = resources.allObjects.first(where: { $0.canServe(dataSpec) }) {
            return resource
        }

        let resource = HTTPResource(dataSpec: dataSpec, sessionLoader: networkLoader)
        resources.add(resource)
        return resource
    }
}

//public final class DefaultDataSource: DataSource {
//    public var isolation: any Actor { queue.playerActor() }
//    public var components: DataSourceOpaque { dataSource?.components ?? fakeComponents }
//
//    private let queue: any Queue
//    private let baseDataSource: any DataSource
//    private let fakeComponents: DataSourceOpaque
//
//    private var fileDataSource: (any DataSource)?
//
//    private var dataSource: (any DataSource)?
//
//    init(
//        queue: any Queue,
//        baseDataSource: any DataSource
//    ) {
//        self.queue = queue
//        self.baseDataSource = baseDataSource
//        self.fakeComponents = DataSourceOpaque(isNetwork: false)
//    }
//
//    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int? {
//        assert(queue.isCurrent())
//        try checkArgument(dataSource == nil)
//
//        let dataSource: any DataSource = if dataSpec.url.isFileURL {
//            try createFileDataSource(dataSpec: dataSpec)
//        } else {
//            baseDataSource
//        }
//
//        self.dataSource = dataSource
//        return try await dataSource.open(dataSpec: dataSpec, isolation: isolation)
//    }
//
//    public func close(isolation: isolated any Actor) async throws {
//        assert(queue.isCurrent())
//        let copyDataSource = dataSource
//        dataSource = nil
//        try await copyDataSource?.close(isolation: isolation)
//    }
//
//    public func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer? {
//        assert(queue.isCurrent())
//
//        return try await dataSource
//            .checkNotNil()
//            .read(range: range, isolation: isolation)
//    }
//
//    public func getURLResponse(isolation: isolated any Actor) -> HTTPURLResponse? {
//        dataSource?.getURLResponse(isolation: isolation)
//    }
//
//    private func createFileDataSource(dataSpec: DataSpec) throws -> any DataSource {
//        if let fileDataSource { return fileDataSource }
//
//        let fileDataSource = try FileDataSource(queue: queue)
//        self.fileDataSource = fileDataSource
//        return fileDataSource
//    }
//}
