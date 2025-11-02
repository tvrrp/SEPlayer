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
    private let queue: Queue
    private let networkLoader: IPlayerSessionLoader
    private let defaultSegmentLenght: Int

    private var requestHandler: DataSource?
    private var originalDataSpec: DataSpec?
    private var currentDataSpec: DataSpec?
    private var currentReadOffset: Int = 0
    private var bytesRemaining: Int?

    init(queue: Queue, networkLoader: IPlayerSessionLoader, segmentLenght: Int? = nil) {
        self.queue = queue
        self.components = DataSourceOpaque(isNetwork: true)
        self.networkLoader = networkLoader
        self.defaultSegmentLenght = segmentLenght ?? .defaultSegmentLenght
    }

    @discardableResult
    func open(dataSpec: DataSpec) throws -> Int {
        assert(queue.isCurrent())
        self.originalDataSpec = dataSpec
        let currentDataSpec = dataSpec.length(defaultSegmentLenght)
        self.currentDataSpec = currentDataSpec
        return try openConnection(dataSpec: currentDataSpec)
    }

    func close() -> ByteBuffer? {
        assert(queue.isCurrent())
        let result = requestHandler?.close()
        requestHandler = nil
        return result
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        guard let requestHandler, let currentDataSpec, let bytesRemaining else { throw DataReaderError.connectionNotOpened }
        let result = try requestHandler.read(to: &buffer, offset: offset, length: length)

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
            try requestHandler.open(dataSpec: newDataSpec)
            return try read(to: &buffer, offset: offset, length: length)
        }
    }

    func read(allocation: Allocation, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
        guard let requestHandler, let currentDataSpec, let bytesRemaining else { throw DataReaderError.connectionNotOpened }
        let result = try requestHandler.read(allocation: allocation, offset: offset, length: length)

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
            try openConnection(dataSpec: newDataSpec)
            return try read(allocation: allocation, offset: offset, length: length)
        }
    }

    private func openConnection(dataSpec: DataSpec) throws -> Int {
        let requestHandler = DefautlHTTPDataSource(
            queue: queue, networkLoader: networkLoader, components: components
        )
        self.requestHandler = requestHandler
        let result = try requestHandler.open(dataSpec: dataSpec)
        guard let urlResponse else { throw DataReaderError.wrongURLResponce }
        bytesRemaining = contentLength(from: urlResponse) - dataSpec.offset
        if bytesRemaining == 0 {
            print()
        }
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
