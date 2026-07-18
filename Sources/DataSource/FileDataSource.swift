//
//  FileDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.07.2025.
//

import Foundation
import SEPlayerCommon

final class FileDataSource: DataSource {
    var url: URL?
    let urlResponse: HTTPURLResponse? = nil

    let components: DataSourceOpaque
    private let syncActor: PlayerActor

    private var readFileHandle: FileHandle?
    private var availableBytes: Int = .zero

    init(syncActor: PlayerActor) {
        self.components = DataSourceOpaque(isNetwork: false)
        self.syncActor = syncActor
    }

    func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int {
        syncActor.assertIsolated()
        let fileUrl = dataSpec.url

        guard let size = try fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw EndOfFileError()
        }

        if fileUrl != url, readFileHandle == nil {
            readFileHandle = try FileHandle(forReadingFrom: fileUrl)
        }

        url = fileUrl
        availableBytes = size

        if dataSpec.position != .zero {
            availableBytes -= dataSpec.position
            try readFileHandle?.seek(toOffset: UInt64(dataSpec.position))
        }

        return size
    }

    func close(isolation: isolated any Actor) async -> ByteBuffer? {
        syncActor.assertIsolated()
        availableBytes = .zero
        return nil
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        guard let readFileHandle else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        guard availableBytes >= length, let data = try readFileHandle.read(upToCount: length) else {
            return .endOfInput
        }

        availableBytes -= data.count
        buffer.writeBytes(data)
        return .success(amount: data.count)
    }

    func read(allocation: Allocation, offset: Int, length: Int, isolation: isolated any Actor) async throws -> DataReaderReadResult {
        syncActor.assertIsolated()
        guard let readFileHandle else {
            throw DataSourceError(reason: .connectionNotOpened)
        }

        guard availableBytes >= length, let data = try readFileHandle.read(upToCount: length) else {
            return .endOfInput
        }

        availableBytes -= data.count
        allocation.writeBytes(offset: offset, lenght: data.count, buffer: data)
        return .success(amount: data.count)
    }
}

import CoreMedia

public final class FileDataSource2: DataSource2 {
    private let queue: any Queue
    private let birstSize: Int
    private var dispatchIO: DispatchIO?
    private var currentError: (any Error)?

    init(queue: any Queue, birstSize: Int = (Int(getpagesize()) * 25)) throws {
        self.queue = queue
        self.birstSize = birstSize
    }

    public func open(dataSpec: DataSpec, isolation: isolated any Actor) async throws -> Int? {
        print("open = \(dataSpec.range2)")
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
        return size
    }

    public func close(isolation: isolated any Actor) async throws {
        dispatchIO?.close(flags: .stop)
        dispatchIO = nil
        currentError = nil
    }

    public func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer {
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

                    print("reading range, range = \(range), data = \(dispatchData?.count), finished = \(finished)")
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
