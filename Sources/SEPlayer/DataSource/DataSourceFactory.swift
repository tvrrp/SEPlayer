//
//  DataSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import Foundation

public protocol DataSourceFactory {
    func createDataSource() -> DataSource
}

public struct DefaultDataSourceFactory: DataSourceFactory {
    private let segmentLength: Int?
    private let loaderQueue: Queue
    private let networkLoader: IPlayerSessionLoader
    private let baseDataSource: DataSource?

    public init(
        segmentLength: Int? = nil,
        loaderQueue: Queue,
        networkLoader: IPlayerSessionLoader,
        baseDataSource: DataSource? = nil
    ) {
        self.segmentLength = segmentLength
        self.loaderQueue = loaderQueue
        self.networkLoader = networkLoader
        self.baseDataSource = baseDataSource
    }

    public func createDataSource() -> DataSource {
        DefaultDataSource(
            segmentLength: segmentLength,
            loaderQueue: loaderQueue,
            networkLoader: networkLoader,
            baseDataSource: baseDataSource ?? RangeRequestHTTPDataSource(
                queue: loaderQueue,
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
    private let loaderQueue: Queue
    private let networkLoader: IPlayerSessionLoader
    private let baseDataSource: DataSource
    private let fakeComponents: DataSourceOpaque

    private var fileDataSource: DataSource?

    private var dataSource: DataSource?

    init(
        segmentLength: Int?,
        loaderQueue: Queue,
        networkLoader: IPlayerSessionLoader,
        baseDataSource: DataSource
    ) {
        self.segmentLength = segmentLength
        self.loaderQueue = loaderQueue
        self.networkLoader = networkLoader
        self.baseDataSource = baseDataSource
        self.fakeComponents = DataSourceOpaque(isNetwork: false)
    }

    func open(dataSpec: DataSpec) throws -> Int {
        assert(loaderQueue.isCurrent())

        guard dataSource == nil else { throw Error.wrongState }

        let dataSource: DataSource

        if dataSpec.url.isFileURL {
            dataSource = createFileDataSource(dataSpec: dataSpec)
        } else {
            dataSource = baseDataSource
        }

        self.dataSource = dataSource
        return try dataSource.open(dataSpec: dataSpec)
    }

    func close() -> ByteBuffer? {
        assert(loaderQueue.isCurrent())
        let copyDataSource = dataSource
        dataSource = nil
        return copyDataSource?.close()
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(loaderQueue.isCurrent())
        guard let dataSource else {
            throw DataReaderError.connectionNotOpened
        }

        return try dataSource.read(to: &buffer, offset: offset, length: length)
    }

    func read(allocation: Allocation, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(loaderQueue.isCurrent())
        guard let dataSource else {
            throw DataReaderError.connectionNotOpened
        }

        return try dataSource.read(allocation: allocation, offset: offset, length: length)
    }

    private func createFileDataSource(dataSpec: DataSpec) -> DataSource {
        if let fileDataSource { return fileDataSource }

        let fileDataSource = FileDataSource(queue: loaderQueue)
        self.fileDataSource = fileDataSource
        return fileDataSource
    }
}

extension DefaultDataSource {
    enum Error: Swift.Error {
        case wrongState
    }
}
