//
//  RangeRequestHTTPDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 12.06.2025.
//

import Foundation

final class RangeRequestHTTPDataSource: DataSource {
    var url: URL? { requestHandler?.url }
    var urlResponse: HTTPURLResponse? { requestHandler?.urlResponse }

    let components: DataSourceOpaque
    private let syncActor: PlayerActor
    private let networkLoader: IPlayerSessionLoader
    private let defaultSegmentLenght: Int

    private var requestHandler: DefautlHTTPDataSource?
    private var originalDataSpec: DataSpec?
    private var currentDataSpec: DataSpec?
    private var currentReadOffset: Int = 0
    private var bytesRemaining: Int?

    init(syncActor: PlayerActor, networkLoader: IPlayerSessionLoader, segmentLenght: Int? = nil) {
        self.syncActor = syncActor
        self.components = DataSourceOpaque(isNetwork: true)
        self.networkLoader = networkLoader
        self.defaultSegmentLenght = segmentLenght ?? .defaultSegmentLenght
    }

    @discardableResult
    func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        syncActor.assertIsolated()
        self.originalDataSpec = dataSpec
        let currentDataSpec = dataSpec.length(defaultSegmentLenght)
        self.currentDataSpec = currentDataSpec
        return try await openConnection(dataSpec: currentDataSpec, isolation: isolation)
    }

    func close(isolation: isolated any Actor) async -> ByteBuffer? {
        syncActor.assertIsolated()
        let result = await requestHandler?.close()
        requestHandler = nil
        return result
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        guard let requestHandler, let currentDataSpec, let bytesRemaining else { throw DataReaderError.connectionNotOpened }
        let result = try await requestHandler.read(to: &buffer, offset: offset, length: length)

        switch result {
        case let .success(amount):
            self.bytesRemaining = bytesRemaining - amount
            return result
        case .endOfInput:
            guard bytesRemaining > 0 else { return .endOfInput }
            let newDataSpec = currentDataSpec
                .offset(currentDataSpec.range.upperBound + 1)
                .length(min(bytesRemaining, max(length, .defaultSegmentLenght)))

            self.currentDataSpec = newDataSpec
            try await requestHandler.open(dataSpec: newDataSpec)
            return try await read(to: &buffer, offset: offset, length: length, isolation: isolation)
        }
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        guard let requestHandler, let currentDataSpec, let bytesRemaining else { throw DataReaderError.connectionNotOpened }
        let result = try await requestHandler.read(allocation: allocation, offset: offset, length: length)

        switch result {
        case let .success(amount):
            self.bytesRemaining = bytesRemaining - amount
            return result
        case .endOfInput:
            guard bytesRemaining > 0 else { return .endOfInput }
            let newDataSpec = currentDataSpec
                .offset(currentDataSpec.range.upperBound + 1)
                .length(min(bytesRemaining, max(length, .defaultSegmentLenght)))

            self.currentDataSpec = newDataSpec
            try await openConnection(dataSpec: newDataSpec, isolation: isolation)
            return try await read(allocation: allocation, offset: offset, length: length, isolation: isolation)
        }
    }

    @discardableResult
    private func openConnection(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        let requestHandler = DefautlHTTPDataSource(
            syncActor: syncActor, networkLoader: networkLoader
        )
        self.requestHandler = requestHandler
        let result = try await requestHandler.open(dataSpec: dataSpec, isolation: isolation)
        guard let urlResponse else { throw DataReaderError.wrongURLResponse }
        bytesRemaining = contentLength(from: urlResponse) - dataSpec.offset
        return result
    }
}

private extension Int {
    static let defaultSegmentLenght = 1024 * 1024 * 10
}

private extension RangeRequestHTTPDataSource {
    func contentLength(from httpResponse: HTTPURLResponse) -> Int {
        httpResponse
            .value(forHeaderKey: "Content-Range")?
            .components(separatedBy: "/").last
            .flatMap(Int.init) ?? 0
    }
    
    func test(from httpResponse: HTTPURLResponse) -> String {
        let string1 = httpResponse.value(forHeaderKey: "Content-Range") ?? "no"
        let string2 = httpResponse.value(forHeaderKey: "Content-Length") ?? "no"
        return string1 + "  " + string2
    }
}

private extension HTTPURLResponse {
    func value(forHeaderKey key: String) -> String? {
        return allHeaderFields
            .first { $0.key.description.caseInsensitiveCompare(key) == .orderedSame }?
            .value as? String
    }
}
