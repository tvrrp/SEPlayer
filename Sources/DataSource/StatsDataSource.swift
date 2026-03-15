//
//  StatsDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import Foundation
import SEPlayerCommon

public final class StatsDataSource: DataSource {
    public var url: URL? { dataSource.url }
    public var urlResponse: HTTPURLResponse? { dataSource.urlResponse }
    public nonisolated var components: DataSourceOpaque { dataSource.components }

    public var bytesRead = 0
    public var lastOpenedUrl: URL?
    public var lastUrlResponse: URLResponse?

    private let dataSource: DataSource

    public init(dataSource: DataSource) {
        self.dataSource = dataSource
    }

    public func resetBytesRead() { bytesRead = 0 }

    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        lastOpenedUrl = dataSpec.url
        lastUrlResponse = nil
        let result = try await dataSource.open(dataSpec: dataSpec, isolation: isolation)

        if let lastOpenedUrl = dataSource.url {
            self.lastOpenedUrl = lastOpenedUrl
        }

        if let lastUrlResponse = dataSource.urlResponse {
            self.lastUrlResponse = lastUrlResponse
        }

        return result
    }

    public func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        let result = try await dataSource.read(to: &buffer, offset: offset, length: length, isolation: isolation)
        if case let .success(amount) = result {
            bytesRead += amount
        }
        return result
    }

    public func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        let result = try await dataSource.read(allocation: allocation, offset: offset, length: length, isolation: isolation)
        if case let .success(amount) = result {
            bytesRead += amount
        }
        return result
    }

    public func close(isolation: isolated any Actor) async throws -> ByteBuffer? {
        try await dataSource.close(isolation: isolation)
    }
}
