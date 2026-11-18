//
//  ParsingLoadable.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.08.2026.
//

import CoreMedia
import DataSource
import Foundation
import SEPlayerCommon

/// A ``Loadable`` for objects that can be parsed from binary data: it reads the whole resource, then parses it.
public final class ParsingLoadable<Result>: Loadable, @unchecked Sendable {
    /// Parses the loaded bytes of the resource at the url. The buffer references the loaded bytes, without a copy.
    public typealias Parser = (_ buffer: CMBlockBuffer, _ url: URL) throws -> Result

    /// The data spec of the load.
    public let dataSpec: DataSpec
    /// An identifier of the load.
    public let loadTaskId: Int

    /// The parsed result once the load completed, or `nil`.
    public var result: Result? { lock.withLock { _result } }
    /// The number of bytes loaded so far.
    public var bytesLoaded: Int { lock.withLock { _bytesLoaded } }

    private let dataSourceFactory: DataSourceFactory
    private let parser: Parser
    private let lock = UnfairLock()
    private var _result: Result? // guarded by lock
    private var _bytesLoaded = 0 // guarded by lock

    public init(dataSpec: DataSpec, dataSourceFactory: DataSourceFactory, parser: @escaping Parser) {
        self.dataSpec = dataSpec
        self.dataSourceFactory = dataSourceFactory
        self.parser = parser
        loadTaskId = LoadEventInfo.nextLoadId()
    }

    public func load(_ isolation: isolated any Actor) async throws {
        lock.withLock { _bytesLoaded = 0 }
        let dataSource = dataSourceFactory.createDataSource()

        do {
            // A source that knows the length is read in one go; any other one in parts until it ends.
            let length = try await dataSource.open(dataSpec: dataSpec, isolation)
            let loaded = try CMBlockBuffer()
            var position = dataSpec.position
            let end = length.map { position + $0 }

            while !Task.isCancelled {
                let length = end.map { $0 - position } ?? Self.readLength
                guard length > 0,
                      let buffer = try await dataSource.read(range: position ..< (position + length), isolation),
                      !buffer.isEmpty else {
                    break
                }

                try loaded.append(bufferReference: buffer)
                position += buffer.dataLength
                lock.withLock { _bytesLoaded = loaded.dataLength }
            }
            try Task.checkCancellation()

            // A redirect changes the base for relative urls in the resource.
            let url = dataSource.getURLResponse(isolation)?.url ?? dataSpec.url
            let result = try parser(loaded, url)
            lock.withLock { _result = result }
        } catch {
            try? await dataSource.close(isolation)
            throw error
        }
        try? await dataSource.close(isolation)
    }

    /// How much a source of unknown length is read at a time.
    private static var readLength: Int { 64 * 1024 }
}
