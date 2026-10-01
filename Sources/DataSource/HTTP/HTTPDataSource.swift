//
//  HTTPDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import Foundation
import CoreMedia
import SEPlayerCommon

/// One consumer's reader of an HTTP resource.
///
/// Data sources of the same URL share one ``HTTPResource``, and with it the downloaded bytes and
/// the running downloads, so several consumers can read the resource at the same time. Closing a
/// data source leaves the others untouched.
public final class HTTPDataSource: DataSource, @unchecked Sendable {
    public let components = DataSourceOpaque(isNetwork: true)
    public var isolation: any Actor { queue.playerActor() }

    private let queue: any Queue
    private let resource: HTTPResource
    private let reader: HTTPResource.Reader
    private var isClosed = false

    init(
        queue: any Queue,
        resource: HTTPResource,
        position: Int,
        _ isolation: isolated any Actor
    ) async throws {
        self.queue = queue
        self.resource = resource
        reader = resource.addReader(at: position)
        reader.dataSource = self
        transferInitializing(source: self)

        // Waits for the response, so the content length is known before the first read.
        _ = try await resource.read(position..<position, for: reader, isolation)
    }

    deinit {
        resource.remove(reader)
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard !isClosed else { throw DataSourceError(reason: .connectionNotOpened) }
        return try await resource.read(range, for: reader, isolation)
    }

    public func close(_ isolation: isolated any Actor) async throws {
        isClosed = true
        resource.remove(reader)
    }

    public func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        resource.response
    }

    public func canHandle(new dataSpec: DataSpec, _ isolation: isolated any Actor) -> Bool {
        resource.canServe(dataSpec)
    }
}
