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
    private let queue: Queue

    private var readFileHandle: FileHandle?
    private var availableBytes: Int = .zero

    init(queue: Queue) {
        self.components = DataSourceOpaque(isNetwork: false)
        self.queue = queue
    }

    func open(dataSpec: DataSpec) throws -> Int {
        assert(queue.isCurrent())
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

    func close() -> ByteBuffer? {
        assert(queue.isCurrent())
        availableBytes = .zero
        return nil
    }

    func read(to buffer: inout ByteBuffer, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
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

    func read(allocation: inout Allocation, offset: Int, length: Int) throws -> DataReaderReadResult {
        assert(queue.isCurrent())
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
