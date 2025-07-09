//
//  DataSourceFactory.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

public protocol DataSourceFactory {
    func createDataSource() -> DataSource
}

public struct DefaultDataSourceFactory: DataSourceFactory {
    let segmentLength: Int?
    let loaderQueue: Queue
    let networkLoader: IPlayerSessionLoader

    public init(segmentLength: Int? = nil, loaderQueue: Queue, networkLoader: IPlayerSessionLoader) {
        self.segmentLength = segmentLength
        self.loaderQueue = loaderQueue
        self.networkLoader = networkLoader
    }

    public func createDataSource() -> DataSource {
        RangeRequestHTTPDataSource(
            queue: loaderQueue,
            networkLoader: networkLoader
        )
//        DefautlHTTPDataSource(
//            queue: loaderQueue,
//            networkLoader: networkLoader
//        )
    }
}
