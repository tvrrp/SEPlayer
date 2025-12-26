//
//  FileDataSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.07.2025.
//

import Foundation

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
            throw DataReaderError.endOfInput
        }

        if fileUrl != url, readFileHandle == nil {
            readFileHandle = try FileHandle(forReadingFrom: fileUrl)
        }

        url = fileUrl
        availableBytes = size

        if dataSpec.offset != .zero {
            availableBytes -= dataSpec.offset
            try readFileHandle?.seek(toOffset: UInt64(dataSpec.offset))
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
            throw DataReaderError.connectionNotOpened
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
            throw DataReaderError.connectionNotOpened
        }

        guard availableBytes >= length, let data = try readFileHandle.read(upToCount: length) else {
            return .endOfInput
        }

        availableBytes -= data.count
        allocation.writeBytes(offset: offset, lenght: data.count, buffer: data)
        return .success(amount: data.count)
    }
}
