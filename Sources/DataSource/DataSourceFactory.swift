//
//  DataSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import Foundation
import SEPlayerCommon

public protocol DataSourceFactory {
    func createDataSource() -> DataSource
}

public struct DefaultDataSourceFactory: DataSourceFactory {
    private let segmentLength: Int?
    private let syncActor: PlayerActor
    private let networkLoader: IPlayerSessionLoader
    private let baseDataSource: DataSource?

    public init(
        segmentLength: Int? = nil,
        syncActor: PlayerActor,
        networkLoader: IPlayerSessionLoader,
        baseDataSource: DataSource? = nil
    ) {
        self.segmentLength = segmentLength
        self.syncActor = syncActor
        self.networkLoader = networkLoader
        self.baseDataSource = baseDataSource
    }

    public func createDataSource() -> DataSource {
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
}

private final class DefaultDataSource: DataSource {
    var components: DataSourceOpaque { dataSource?.components ?? fakeComponents }
    var url: URL? { dataSource?.url }
    var urlResponse: HTTPURLResponse? { dataSource?.urlResponse }

    private let segmentLength: Int?
    private let syncActor: PlayerActor
    private let networkLoader: IPlayerSessionLoader
    private let baseDataSource: DataSource
    private let fakeComponents: DataSourceOpaque

    private var fileDataSource: DataSource?

    private var dataSource: DataSource?

    init(
        segmentLength: Int?,
        syncActor: PlayerActor,
        networkLoader: IPlayerSessionLoader,
        baseDataSource: DataSource
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

        let dataSource: DataSource = if dataSpec.url.isFileURL {
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

    private func createFileDataSource(dataSpec: DataSpec) -> DataSource {
        if let fileDataSource { return fileDataSource }

        let fileDataSource = FileDataSource(syncActor: syncActor)
        self.fileDataSource = fileDataSource
        return fileDataSource
    }
}
