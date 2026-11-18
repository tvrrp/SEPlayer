//
//  HTTPDataSource.swift
//  SEPlayer
//
//  Created by tvrrp on 20.06.2026.
//

import Foundation
import CoreMedia
import SEPlayerCommon

/// A ``DataSource`` that reads an HTTP resource.
///
/// The bytes are loaded with range requests and cached by an ``HTTPResource``. Data sources of one factory that read
/// the same URL share that resource, so the bytes one of them loaded are not requested again by another.
public final class HTTPDataSource: DataSource, @unchecked Sendable {
    public let components = DataSourceOpaque(isNetwork: true)
    public var isolation: any Actor { queue.playerActor() }

    private let queue: any Queue
    /// Returns the resource of a data spec, shared with the other data sources of the factory.
    private let resourceProvider: (DataSpec) -> HTTPResource
    private var resource: HTTPResource?
    private var reader: HTTPResource.Reader?
    private var readAhead: ReadAhead?

    init(
        queue: any Queue,
        transferListener: TransferListener? = nil,
        resourceProvider: @escaping (DataSpec) -> HTTPResource
    ) {
        self.queue = queue
        self.resourceProvider = resourceProvider
        if let transferListener {
            addTransferListener(transferListener)
        }
    }

    deinit {
        if let reader {
            resource?.remove(reader)
        }
    }

    public func open(dataSpec: DataSpec, _ isolation: isolated any Actor) async throws -> Int? {
        guard reader == nil else {
            throw DataSourceError(reason: .alreadyOpened)
        }

        let resource = resourceProvider(dataSpec)
        // Requests end where the data spec ends, or at the end of the resource for one without a length.
        let end = dataSpec.length.map { dataSpec.position + $0 }
        let reader = resource.addReader(at: dataSpec.position, end: end, readAhead: readAhead)
        reader.dataSource = self
        self.resource = resource
        self.reader = reader
        transferInitializing(source: self)

        do {
            // An empty read waits for the first response, which tells the length of the resource.
            let emptyRange = dataSpec.position..<dataSpec.position
            _ = try await resource.read(emptyRange, for: reader, isolation)
        } catch {
            try? await close(isolation)
            throw error
        }

        guard let resourceLength = resource.response?.resourceLength else {
            return dataSpec.length
        }

        let available = max(0, resourceLength - dataSpec.position)
        return dataSpec.length.map { min($0, available) } ?? available
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard let resource, let reader else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        return try await resource.read(range, for: reader, isolation)
    }

    public func close(_ isolation: isolated any Actor) async throws {
        if let reader {
            resource?.remove(reader)
        }
        reader = nil
        resource = nil
    }

    public func getURLResponse(_ isolation: isolated any Actor) -> HTTPURLResponse? {
        resource?.response
    }

    public func setReadAhead(_ readAhead: ReadAhead?) {
        self.readAhead = readAhead
    }
}
