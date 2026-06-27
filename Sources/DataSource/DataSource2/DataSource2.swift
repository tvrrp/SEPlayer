//
//  DataSource2.swift
//  SEPlayer
//
//  Created by tvrrp on 19.05.2026.
//

import CoreMedia
import SEPlayerCommon

public struct ResourceInfo: Sendable, Equatable {
    public let length: Int
    public let contentType: String?
    public let validators: ResourceValidators?

    public struct ResourceValidators: Sendable, Equatable {
        public let etag: String?
        public let lastModified: Date?

        public init(etag: String?, lastModified: Date?) {
            self.etag = etag
            self.lastModified = lastModified
        }
    }

    public init(length: Int, contentType: String?, validators: ResourceValidators?) {
        self.length = length
        self.contentType = contentType
        self.validators = validators
    }
}

public protocol DataSource2: DataReader2 {
    @discardableResult func probe(isolation: isolated any Actor) async throws -> ResourceInfo
    @discardableResult func close(isolation: isolated any Actor) async throws
//    func setFetchPolicy(_ policy: FetchPolicy, isolation: isolated PlayerActor) async
}

public protocol DataReader2 {
    func read(range: Range<Int>, readPolicy: ReadPolicy, isolation: isolated any Actor) async throws -> CMBlockBuffer
}

public extension DataReader2 {
    func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer {
        try await read(range: range, readPolicy: .contigious, isolation: isolation)
    }
}

public protocol FetchPolicy: Sendable {
    var fetchUpTo: Int { get }
    var keepBytesFrom: Int { get }
    var maxCachedBytes: Int { get }
}

struct DefaultFetchPolicy: FetchPolicy {
    let fetchUpTo: Int = .max
    let keepBytesFrom: Int = 0
    let maxCachedBytes: Int = 32 * 1024 * 1024
}

public enum ReadPolicy {
    case contigious
    case oneShot
}
