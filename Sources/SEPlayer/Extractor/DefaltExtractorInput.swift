//
//  DefaltExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation.NSRange

final class DefaltExtractorInput: ExtractorInput {
    private let dataReader: DataReader
    private let streamLength: Int

    private var position: Int
    private var peekBuffer: ByteBuffer
    private var peekBufferPosition: Int
    private var peekBufferLength: Int

    let queue: Queue

    init(dataReader: DataReader, queue: Queue, range: NSRange? = nil) {
        self.dataReader = dataReader
        self.position = range?.location ?? 0
        self.streamLength = range?.length ?? 0

        self.peekBuffer = ByteBuffer()
        self.peekBufferPosition = 0
        self.peekBufferLength = 0
        self.queue = queue
    }

    func read(to buffer: ByteBuffer, offset: Int, length: Int, completion: @escaping (ExtractorInputReadResult) -> Void) {
        assert(queue.isCurrent())
        var intermidiateBuffer = buffer
        let bytesReadFromPeak = readFromPeekBuffer(target: &intermidiateBuffer, offset: offset, length: length)

        func completeTask(buffer: ByteBuffer, bytesRead: Int) {
            commitBytesRead(bytesRead)

            if bytesRead != .resultEndOfInput {
                completion(.bytesRead(buffer, bytesRead))
            } else {
                completion(.endOfInput)
            }
        }

        if bytesReadFromPeak == 0 {
            readFromUpstream(target: buffer, offset: offset, length: length, bytesAlreadyRead: 0, allowEndOfInput: true) { result in
                switch result {
                case let .success((buffer, bytesRead)):
                    completeTask(buffer: buffer, bytesRead: bytesReadFromPeak + bytesRead)
                case .failure(_):
                    completeTask(buffer: buffer, bytesRead: bytesReadFromPeak)
                }
            }
        } else {
            completeTask(buffer: intermidiateBuffer, bytesRead: bytesReadFromPeak)
        }
    }

    func read(allocation: Allocation, offset: Int, length: Int, completionQueue: any Queue, completion: @escaping (Result<(Int), any Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { completionQueue.async { completion(.failure(DataReaderError.endOfInput)) }; return }
            dataReader.read(allocation: allocation, offset: offset, length: length, completionQueue: queue) { result in
                if case let .success(bytesRead) = result {
                    self.commitBytesRead(bytesRead)
                }
                completionQueue.async { completion(result) }
            }
        }
    }

    func skip(length: Int, completion: @escaping (DataReaderError?) -> Void) {
        guard length > 0 else { completion(nil); return }
        let bytesSkipped = skipFromPeekBuffer(length: length)

        func completeTask(bytesSkipped: Int) {
            commitBytesRead(bytesSkipped)

            if bytesSkipped != .resultEndOfInput {
                completion(nil)
            } else {
                completion(.endOfInput)
            }
        }

        if bytesSkipped == 0 {
            readFromUpstream(target: ByteBuffer(), offset: 0, length: length, bytesAlreadyRead: 0, allowEndOfInput: true) { result in
                switch result {
                case let .success((_, bytesRead)):
                    completeTask(bytesSkipped: bytesRead)
                case .failure(_):
                    completeTask(bytesSkipped: bytesSkipped)
                }
            }
        } else {
            completeTask(bytesSkipped: bytesSkipped)
        }
    }

    func peek(to buffer: ByteBuffer, offset: Int, length: Int, completion: @escaping (ExtractorInputReadResult) -> Void) {
        var intermidiateBuffer = buffer
        let peekBufferRemainingBytes = peekBufferLength - peekBufferPosition

        func completeTask(buffer: ByteBuffer, lenght: Int) {
            self.peekBuffer = buffer
            peekBuffer.moveReaderIndex(to: peekBufferPosition)
            guard let data = peekBuffer.readData(length: length) else { completion(.endOfInput); return }
            intermidiateBuffer.moveWriterIndex(to: offset)
            intermidiateBuffer.writeBytes(data)
            completion(.bytesRead(intermidiateBuffer, length))
            peekBufferPosition += length
            peekBufferLength += lenght
            return
        }

        if peekBufferRemainingBytes < length {
            let bytesToPeek = length - peekBufferRemainingBytes
            readFromUpstream(target: peekBuffer, offset: peekBufferPosition, length: bytesToPeek, bytesAlreadyRead: 0, allowEndOfInput: true) { result in
                switch result {
                case let .success((buffer, length)):
                    completeTask(buffer: buffer, lenght: length)
                case .failure(_):
                    completion(.endOfInput)
                }
            }
        } else {
            completeTask(buffer: peekBuffer, lenght: length)
        }
    }

    func advancePeekPosition(lenght: Int, completion: @escaping (DataReaderError?) -> Void) {
        readFromUpstream(target: peekBuffer, offset: peekBufferPosition, length: lenght, bytesAlreadyRead: .zero, allowEndOfInput: true) { result in
            switch result {
            case let .success((buffer, length)):
                self.peekBuffer = buffer
                self.peekBufferLength += lenght
                self.peekBufferPosition += length
                completion(nil)
            case .failure(_):
                completion(.endOfInput)
            }
        }
    }

    func resetPeekPosition() {
        assert(queue.isCurrent())
        peekBufferPosition = 0
    }

    func getPeekPosition() -> Int {
        assert(queue.isCurrent())
        return position + peekBufferPosition
    }

    func getPosition() -> Int {
        assert(queue.isCurrent())
        return position
    }

    func getLength() -> Int {
        assert(queue.isCurrent())
        return streamLength
    }
}

private extension DefaltExtractorInput {
    private func skipFromPeekBuffer(length: Int) -> Int {
        let bytesSkipped = min(peekBufferLength, length)
        updatePeekBuffer(bytesConsumed: bytesSkipped)
        return bytesSkipped
    }

    private func readFromPeekBuffer(
        target: inout ByteBuffer,
        offset: Int, length: Int
    ) -> Int {
        guard peekBufferLength > 0 else { return 0 }
        let peekBytes = min(peekBufferLength, length)
        guard let bytes = peekBuffer.readBytes(length: peekBytes) else { return 0 }
        target.moveWriterIndex(to: offset)
        target.writeBytes(bytes)

        updatePeekBuffer(bytesConsumed: peekBytes)
        return peekBytes
    }

    private func updatePeekBuffer(bytesConsumed: Int) {
        peekBufferLength -= bytesConsumed
        peekBufferPosition = 0
        let newPeekBuffer = ByteBuffer(buffer: peekBuffer)

        if peekBufferLength < peekBuffer.capacity - .peekMaxFreeSpace {
            peekBuffer.reserveCapacity(peekBufferLength + .peekMinFreeSpaceAfterResize)
        }

        peekBuffer = newPeekBuffer
    }

    private func readFromUpstream(
        target: ByteBuffer,
        offset: Int, length: Int,
        bytesAlreadyRead: Int,
        allowEndOfInput: Bool,
        completion: @escaping (Result<(ByteBuffer, Int), DataReaderError>) -> Void
    ) {
        assert(queue.isCurrent())
        dataReader.read(to: target, offset: offset, length: length, completionQueue: queue) { result in
            switch result {
            case let .success((buffer, bytesRead)):
                completion(.success((buffer, bytesAlreadyRead + bytesRead)))
            case .failure(_):
                if bytesAlreadyRead == 0 && allowEndOfInput {
                    completion(.success((target, .resultEndOfInput)))
                } else {
                    completion(.failure(DataReaderError.endOfInput))
                }
            }
        }
    }

    private func commitBytesRead(_ bytesRead: Int) {
        assert(queue.isCurrent())
        if bytesRead != .resultEndOfInput {
            position += bytesRead
        }
    }
}

private extension Int {
    static let peekMinFreeSpaceAfterResize: Int = 64 * 1024
    static let peekMaxFreeSpace: Int = 512 * 1024
    static let scratchSpaceSize: Int = 4096
    static let resultEndOfInput: Int = -1

    func clamp(range: Range<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
