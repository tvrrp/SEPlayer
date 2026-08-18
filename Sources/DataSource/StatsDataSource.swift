//
//  StatsDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//

import Foundation
import CoreMedia
import SEPlayerCommon

public final class StatsDataSource: DataSource {
    public var isolation: any Actor { dataSource.isolation }
    public nonisolated var components: DataSourceOpaque { dataSource.components }

    public var bytesRead = 0
    public var lastOpenedUrl: URL?
    public var lastUrlResponse: URLResponse?

    private let dataSource: DataSource

    public init(dataSource: DataSource) {
        self.dataSource = dataSource
    }

//    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int? {
//        lastOpenedUrl = dataSpec.url
//        lastUrlResponse = nil
//
//        let result = try await dataSource.open(dataSpec: dataSpec, isolation: isolation)
////        TODO: if let lastOpenedUrl = dataSource.url {
////            self.lastOpenedUrl = lastOpenedUrl
////        }
//
//        if let lastUrlResponse = dataSource.getURLResponse(isolation: isolation) {
//            self.lastUrlResponse = lastUrlResponse
//        }
//
//        return result
//    }
    public func canHandle(new dataSpec: DataSpec, _ isolation: isolated any Actor) -> Bool {
        dataSource.canHandle(new: dataSpec, isolation)
    }

    public func close(_ isolation: isolated any Actor) async throws {
        try await dataSource.close(isolation)
    }

    public func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        dataSource.getURLResponse(isolation)
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        let sampleBuffer = try await dataSource.read(range: range, isolation)
        if let sampleBuffer, !sampleBuffer.isEmpty {
            bytesRead += sampleBuffer.dataLength
        }
        return sampleBuffer
    }
}
