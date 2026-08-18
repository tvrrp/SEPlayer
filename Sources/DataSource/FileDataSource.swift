//
//  FileDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.07.2025.
//

import Foundation
import CoreMedia
import SEPlayerCommon

public final class FileDataSource: DataSource {
    public var isolation: any Actor { queue.playerActor() }
    public let components: DataSourceOpaque

    private let queue: any Queue
    private let dataSpec: DataSpec
    private var contentLenght: Int?

    private let birstSize: Int
    private var dispatchIO: DispatchIO?
    private var currentError: (any Error)?

    init(
        queue: any Queue,
        dataSpec: DataSpec,
        birstSize: Int = (Int(getpagesize()) * 25),
        _ isolation: isolated any Actor
    ) async throws {
        self.queue = queue
        self.dataSpec = dataSpec
        self.birstSize = birstSize
        components = DataSourceOpaque(isNetwork: false)

        try open(isolation)
    }

    public func getContentLenght(dataSpec: DataSpec, _ isolation: isolated any Actor) -> Int? {
        self.contentLenght
    }

    public func canHandle(new dataSpec: DataSpec, _ isolation: isolated any Actor) -> Bool {
        guard self.dataSpec.url == dataSpec.url else { return false }

        return true
    }

    private func open(_ isolation: isolated any Actor) throws {
        guard dispatchIO == nil else {
            throw DataSourceError(reason: .alreadyOpened)
        }

        guard let size = try dataSpec.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw EndOfFileError()
        }

        guard let filePath = (dataSpec.url.path as NSString).utf8String else {
            throw DataSourceError(reason: .unknown)
        }

        dispatchIO = DispatchIO(
            type: .random,
            path: filePath,
            oflag: 0,
            mode: 0,
            queue: queue.queue,
            cleanupHandler: { [weak self] error in
                if error != noErr {
                    self?.currentError = NSError(domain: NSOSStatusErrorDomain, code: Int(error))
                }
            }
        )

        guard let dispatchIO, currentError == nil else {
            throw DataSourceError(reason: .unknown)
        }

        dispatchIO.setLimit(lowWater: .max)
        contentLenght = size
    }

    public func close(_ isolation: isolated any Actor) async throws {
//        dispatchIO?.close(flags: .stop)
//        dispatchIO = nil
//        currentError = nil
    }

    public func read(range: Range<Int>, _ isolation: isolated any Actor) async throws -> CMBlockBuffer? {
        guard let dispatchIO else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        if let currentError {
            throw currentError
        }

        let blockBuffer = try CMBlockBuffer()
        var errorInReadOperation: (any Error)?

        return try await withCheckedThrowingContinuation { continuation in
            dispatchIO.read(
                offset: off_t(range.startIndex),
                length: range.count,
                queue: queue.queue,
                ioHandler: { [weak self] finished, dispatchData, error in
                    guard let self else { return }

                    if let errorInReadOperation {
                        if finished {
                            continuation.resume(throwing: errorInReadOperation)
                        }

                        return
                    }

                    guard let dispatchData else {
                        if error != 0 {
                            continuation.resume(throwing: EndOfFileError())
                        } else if finished {
                            continuation.resume(returning: blockBuffer)
                        } else {
                            continuation.resume(throwing: EndOfFileError())
                        }

                        return
                    }

                    do {
                        try handleRead(dispatchData, blockBuffer: blockBuffer)
                        if finished { continuation.resume(returning: blockBuffer) }
                    } catch {
                        errorInReadOperation = error
                    }
                }
            )
        }
    }

    private func handleRead(_ data: DispatchData, blockBuffer: CMBlockBuffer) throws {
        var enumerationError: (any Error)?
        data.enumerateBytes { bufferPointer, byteIndex, stop in
            do {
                try blockBuffer.append(
                    buffer: UnsafeMutableRawBufferPointer(
                        mutating: UnsafeRawBufferPointer(bufferPointer)
                    ),
                    deallocator: { _, _ in
                        withExtendedLifetime(data) {}
                    }
                )
            } catch {
                enumerationError = error
                stop = true
            }
        }

        if let enumerationError {
            throw enumerationError
        }
    }
}
