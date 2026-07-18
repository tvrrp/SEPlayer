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
    func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int?
    func close(isolation: isolated any Actor) async throws
    func getUrlResponse() -> HTTPURLResponse?
//    func setFetchPolicy(_ policy: FetchPolicy, isolation: isolated PlayerActor) async
}

public protocol DataSource3: DataReader3 {
    var urlResponse: HTTPURLResponse? { get async }
    func open(dataSpec: DataSpec) async throws -> Int?
    func close() async
//    func getUrlResponse() async -> HTTPURLResponse?
//    func setFetchPolicy(_ policy: FetchPolicy, isolation: isolated PlayerActor) async
}

public extension DataSource2 {
    func getUrlResponse() -> HTTPURLResponse? { nil }
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
