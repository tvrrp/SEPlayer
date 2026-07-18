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
    func createDataSource() -> any DataSource
    func createDataSource2() -> any DataSource2
}

public struct DefaultDataSourceFactory<NetworkLoader: IPlayerSessionLoader>: DataSourceFactory {
    private let segmentLength: Int?
    private let syncActor: PlayerActor
    private let networkLoader: NetworkLoader
    private let baseDataSource: (any DataSource)?

    public init(
        segmentLength: Int? = nil,
        syncActor: PlayerActor,
        networkLoader: NetworkLoader,
        baseDataSource: (any DataSource)? = nil
    ) {
        self.segmentLength = segmentLength
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.baseDataSource = baseDataSource
    }

    public func createDataSource() -> any DataSource {
        DefaultDataSource(
            segmentLength: segmentLength,
            syncActor: syncActor,
            networkLoader: networkLoader,
            baseDataSource: baseDataSource ?? RangeRequestHTTPDataSource(
                syncActor: syncActor,
                networkLoader: networkLoader
            )
        )
    }

    public func createDataSource2() -> any DataSource2 {
        let queue = syncActor.executor.queue
        return DefaultDataSource2(
            queue: queue,
            baseDataSource: HTTPDataSource2(
                queue: queue,
                transportFactory: DefaultHTTPTransportFactory(
                    loadQueue: queue,
                    sessionLoader: networkLoader
                )
            )
        )
    }
}

private final class DefaultDataSource: DataSource {
    var components: DataSourceOpaque { dataSource?.components ?? fakeComponents }
    var url: URL? { dataSource?.url }
    var urlResponse: HTTPURLResponse? { dataSource?.urlResponse }

    private let segmentLength: Int?
    private let syncActor: PlayerActor
    private let networkLoader: any IPlayerSessionLoader
    private let baseDataSource: any DataSource
    private let fakeComponents: DataSourceOpaque

    private var fileDataSource: (any DataSource)?

    private var dataSource: (any DataSource)?

    init(
        segmentLength: Int?,
        syncActor: PlayerActor,
        networkLoader: any IPlayerSessionLoader,
        baseDataSource: any DataSource
    ) {
        self.segmentLength = segmentLength
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.baseDataSource = baseDataSource
        self.fakeComponents = DataSourceOpaque(isNetwork: false)
    }

    func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        syncActor.assertIsolated()
        try checkArgument(dataSource == nil)

        let dataSource: any DataSource = if dataSpec.url.isFileURL {
            createFileDataSource(dataSpec: dataSpec)
        } else {
            baseDataSource
        }

        self.dataSource = dataSource
        return try await dataSource.open(dataSpec: dataSpec, isolation: isolation)
    }

    func close(isolation: isolated any Actor) async throws -> ByteBuffer? {
        syncActor.assertIsolated()
        let copyDataSource = dataSource
        dataSource = nil
        return try await copyDataSource?.close(isolation: isolation)
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()

        return try await dataSource
            .checkNotNil()
            .read(to: &buffer, offset: offset, length: length, isolation: isolation)
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()

        return try await dataSource
            .checkNotNil()
            .read(allocation: allocation, offset: offset, length: length, isolation: isolation)
    }

    private func createFileDataSource(dataSpec: DataSpec) -> any DataSource {
        if let fileDataSource { return fileDataSource }

        let fileDataSource = FileDataSource(syncActor: syncActor)
        self.fileDataSource = fileDataSource
        return fileDataSource
    }
}

public final class DefaultDataSource2: DataSource2 {
    private let queue: any Queue
    private let baseDataSource: any DataSource2
//    private let fakeComponents: DataSourceOpaque

    private var fileDataSource: (any DataSource2)?

    private var dataSource: (any DataSource2)?

    init(
        queue: any Queue,
        baseDataSource: any DataSource2
    ) {
        self.queue = queue
        self.baseDataSource = baseDataSource
//        self.fakeComponents = DataSourceOpaque(isNetwork: false)
    }

    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int? {
        assert(queue.isCurrent())
        try checkArgument(dataSource == nil)

        let dataSource: any DataSource2 = if dataSpec.url.isFileURL {
            try createFileDataSource(dataSpec: dataSpec)
        } else {
            baseDataSource
        }

        self.dataSource = dataSource
        return try await dataSource.open(dataSpec: dataSpec, isolation: isolation)
    }

    public func close(isolation: isolated any Actor) async throws {
        assert(queue.isCurrent())
        let copyDataSource = dataSource
        dataSource = nil
        try await copyDataSource?.close(isolation: isolation)
    }

    public func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        assert(queue.isCurrent())

        return try await dataSource
            .checkNotNil()
            .read(range: range, isolation: isolation)
    }

    public func getUrlResponse() -> HTTPURLResponse? {
        dataSource?.getUrlResponse()
    }

    private func createFileDataSource(dataSpec: DataSpec) throws -> any DataSource2 {
        if let fileDataSource { return fileDataSource }

        let fileDataSource = try FileDataSource2(queue: queue)
        self.fileDataSource = fileDataSource
        return fileDataSource
    }
}
