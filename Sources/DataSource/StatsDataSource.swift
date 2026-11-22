//
//  StatsDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.datasource.StatsDataSource
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Foundation
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

    public func open(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> Int? {
        lastOpenedUrl = dataSpec.url
        lastUrlResponse = nil
        let length = try await dataSource.open(dataSpec: dataSpec, isolation)
        lastUrlResponse = dataSource.getURLResponse(isolation)
        return length
    }

    public func close(_ isolation: isolated any Actor) async throws {
        try await dataSource.close(isolation)
    }

    public func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        dataSource.getURLResponse(isolation)
    }

    public func setReadAhead(_ readAhead: ReadAhead?) {
        dataSource.setReadAhead(readAhead)
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        let sampleBuffer = try await dataSource.read(range: range, isolation)
        if let sampleBuffer, !sampleBuffer.isEmpty {
            bytesRead += sampleBuffer.dataLength
        }
        return sampleBuffer
    }
}
