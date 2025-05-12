//
//  RangeRequestHTTPDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

final class RangeRequestHTTPDataSource: DataSource {
    var url: URL? { requestHandler.url }
    var urlResponce: HTTPURLResponse? { requestHandler.urlResponce }

    let components: DataSourceOpaque
    let queue: Queue
    private let networkLoader: IPlayerSessionLoader
    private let defaultSegmentLenght: Int

    private var requestHandler: DataSource
    private var originalDataSpec: DataSpec?
    private var currentDataSpec: DataSpec?
    private var currentReadOffset: Int = 0

    init(queue: Queue, networkLoader: IPlayerSessionLoader, segmentLenght: Int = .defaultSegmentLenght) {
        self.queue = queue
        self.components = DataSourceOpaque(isNetwork: true)
        self.networkLoader = networkLoader
        self.defaultSegmentLenght = segmentLenght
        self.requestHandler = DefautlHTTPDataSource(
            queue: queue, networkLoader: networkLoader, components: components
        )
    }

    func open(dataSpec: DataSpec, completionQueue: Queue, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { completionQueue.async { completion(.failure(CancellationError())) }; return }
            self.originalDataSpec = dataSpec
            let currentDataSpec = dataSpec.length(defaultSegmentLenght)
            self.currentDataSpec = currentDataSpec
            requestHandler.open(dataSpec: currentDataSpec, completionQueue: completionQueue, completion: completion)
        }
    }

    func read(to buffer: ByteBuffer, offset: Int, length: Int, completionQueue: Queue, completion: @escaping (Result<(ByteBuffer, Int), any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let currentDataSpec else {
                completionQueue.async { completion(.failure(DataReaderError.connectionNotOpened)) }; return
            }

            requestHandler.read(to: buffer, offset: offset, length: length, completionQueue: queue) { [weak self] result in
                guard let self else { return }

                switch result {
                case let .success((buffer, bytesRead)):
                    if bytesRead == length {
                        completionQueue.async { completion(.success((buffer, bytesRead))) }
                    } else {
                        let newDataSpec = currentDataSpec
                            .offset(currentDataSpec.range.upperBound + 1)
                            .length(max(defaultSegmentLenght, length - bytesRead))

                        self.currentDataSpec = newDataSpec

                        open(dataSpec: newDataSpec, completionQueue: queue) { openResult in
                            switch openResult {
                            case .success(_):
                                self.read(to: buffer, offset: offset + bytesRead, length: length - bytesRead, completionQueue: self.queue) { result in
                                    switch result {
                                    case let .success((buffer, bytesReadAfterNewConnection)):
                                        completionQueue.async { completion(.success((buffer, bytesRead + bytesReadAfterNewConnection))) }
                                    case let .failure(error):
                                        completionQueue.async { completion(.failure(error)) }
                                    }
                                }
                            case let .failure(error):
                                completionQueue.async { completion(.failure(error)) }
                            }
                        }
                    }
                case let .failure(error):
                    completionQueue.async { completion(.failure(error)) }
                }
            }
        }
    }

    func read(allocation: Allocation, offset: Int, length: Int, completionQueue: Queue, completion: @escaping (Result<(Int), any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let currentDataSpec else {
                completionQueue.async { completion(.failure(DataReaderError.connectionNotOpened)) }; return
            }

            requestHandler.read(allocation: allocation, offset: offset, length: length, completionQueue: queue) { [weak self] result in
                guard let self else { return }

                switch result {
                case let .success(bytesRead):
                    if bytesRead == length {
                        completionQueue.async { completion(.success(bytesRead)) }
                    } else {
                        let newDataSpec = currentDataSpec
                            .offset(currentDataSpec.range.upperBound + 1)
                            .length(max(defaultSegmentLenght, length - bytesRead))

                        self.currentDataSpec = newDataSpec

                        open(dataSpec: newDataSpec, completionQueue: queue) { openResult in
                            switch openResult {
                            case .success(_):
                                self.read(allocation: allocation, offset: offset + bytesRead, length: length - bytesRead, completionQueue: self.queue) { result in
                                    switch result {
                                    case let .success(bytesReadAfterNewConnection):
                                        completionQueue.async { completion(.success(bytesRead + bytesReadAfterNewConnection)) }
                                    case let .failure(error):
                                        completionQueue.async { completion(.failure(error)) }
                                    }
                                }
                            case let .failure(error):
                                completionQueue.async { completion(.failure(error)) }
                            }
                        }
                    }
                case let .failure(error):
                    completionQueue.async { completion(.failure(error)) }
                }
            }
        }
    }
    
    @discardableResult
    func close() -> ByteBuffer? {
        queue.sync { [weak self] in
            return self?.requestHandler.close()
        }
    }
}

private extension Int {
    static let defaultSegmentLenght = 1024 * 1024
}
