//
//  DefaltExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation
import CoreMedia

final class DefaltExtractorInput: ExtractorInput {
    private let dataReader: DataReader
    private let streamLength: Int

    private var scratchSpace: ByteBuffer
    private var scratchSpaceCapacity: Int

    private var position: Int
    nonisolated(unsafe) private var peekBuffer: ByteBuffer
    private var peekBufferPosition: Int
    private var peekBufferLength: Int

    let queue: Queue

    init(dataReader: DataReader, queue: Queue, range: NSRange? = nil) {
        self.dataReader = dataReader
        self.position = range?.location ?? 0
        self.streamLength = range?.length ?? 0

        self.scratchSpace = ByteBuffer()
        self.scratchSpaceCapacity = .scratchSpaceSize

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

    func read(allocation: Allocation2, offset: Int, length: Int, completionQueue: any Queue, completion: @escaping (Result<(Int), any Error>) -> Void) {
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

//    func read(blockBuffer: CMBlockBuffer, offset: Int, length: Int, completionQueue: any Queue, completion: @escaping (Result<(Int), any Error>) -> Void) {
//        queue.async { [weak self] in
//            guard let self else { completionQueue.async { completion(.failure(DataReaderError.endOfInput)) }; return }
//            dataReader.read(blockBuffer: blockBuffer, offset: offset, length: length, completionQueue: queue) { result in
//                if case let .success(bytesRead) = result {
//                    self.commitBytesRead(bytesRead)
//                }
//                completionQueue.async { completion(result) }
//            }
//        }
//    }

//    @discardableResult
//    func readFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowsEndOfInput: Bool) async throws -> Bool {
//        executor.assertIsolated()
//        var bytesRead = readFromPeekBuffer(target: &buffer, offset: offset, length: length)
//        while bytesRead < length && bytesRead != .resultEndOfInput {
//            bytesRead = try await readFromUpstream(
//                target: &buffer, offset: offset, length: length, bytesAlreadyRead: bytesRead, allowEndOfInput: allowsEndOfInput
//            )
//        }
//        commitBytesRead(bytesRead)
//        return bytesRead != .resultEndOfInput
//    }

//    func readFully(to buffer: ByteBuffer, offset: Int, length: Int, allowsEndOfInput: Bool, completion: @escaping @Sendable (Result<(ByteBuffer, Bool), DataReaderError>) -> Void) {
//        assert(queue.isCurrent())
//        var intermidiateBuffer = buffer
//        let bytesReadFromPeak = readFromPeekBuffer(target: &intermidiateBuffer, offset: offset, length: length)
//
//        @Sendable func completeTask(buffer: ByteBuffer, bytesRead: Int) {
//            commitBytesRead(bytesRead)
//            completion(.success((buffer, bytesRead != .resultEndOfInput)))
//        }
//
//        guard bytesReadFromPeak < length && bytesReadFromPeak != .resultEndOfInput else {
//            completeTask(buffer: intermidiateBuffer, bytesRead: bytesReadFromPeak); return
//        }
//
//        var closure = { () -> Bool in
////            return bytesReadFromPeak < length && bytesReadFromPeak != .resultEndOfInput
//        }
//
//        readFromPeekBuffer(target: &intermidiateBuffer, offset: offset, length: length)
//    }

//    func skip(length: Int) async throws -> ExtractorInputReadResult {
//        var bytesSkipped = skipFromPeekBuffer(length: length)
//        if bytesSkipped == 0 {
//            var scratchSpace = ByteBuffer()
//            bytesSkipped = try await readFromUpstream(
//                target: &scratchSpace,
//                offset: 0, length: min(length, scratchSpaceCapacity),
//                bytesAlreadyRead: 0,
//                allowEndOfInput: true
//            )
//        }
//        commitBytesRead(bytesSkipped)
//
//        if bytesSkipped != .resultEndOfInput {
//            return .bytesRead(bytesSkipped)
//        } else {
//            return .endOfInput
//        }
//    }

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

//    @discardableResult
//    func skipFully(length: Int, allowsEndOfInput: Bool) async throws -> Bool {
//        var bytesSkipped = skipFromPeekBuffer(length: length)
//        while bytesSkipped < length && bytesSkipped != .resultEndOfInput {
//            let minLength =  min(length, bytesSkipped + scratchSpaceCapacity)
//            var scratchSpace = ByteBuffer()
//            bytesSkipped = try await readFromUpstream(
//                target: &scratchSpace,
//                offset: bytesSkipped - 1, length: minLength,
//                bytesAlreadyRead: bytesSkipped,
//                allowEndOfInput: allowsEndOfInput
//            )
//        }
//        commitBytesRead(bytesSkipped)
//        return bytesSkipped != .resultEndOfInput
//    }
    
    func skipFully(length: Int, allowsEndOfInput: Bool, completion: @escaping (Result<Bool, DataReaderError>) -> Void) {
        
    }

//    func peek(to buffer: inout ByteBuffer, offset: Int, length: Int) async throws -> ExtractorInputReadResult {
//        let peekBufferRemainingBytes = peekBufferLength - peekBufferPosition
//        var bytesPeeked: Int
//        if peekBufferRemainingBytes == 0 {
//            bytesPeeked = try await readFromUpstream(
//                target: &peekBuffer, offset: peekBufferPosition, length: length, bytesAlreadyRead: 0, allowEndOfInput: true
//            )
//            if bytesPeeked == .resultEndOfInput {
//                return .endOfInput
//            }
//            peekBufferLength += bytesPeeked
//        } else {
//            bytesPeeked = min(length, peekBufferRemainingBytes)
//        }
//        peekBuffer.moveReaderIndex(to: peekBufferPosition)
//        guard let data = peekBuffer.readData(length: bytesPeeked) else { return .endOfInput }
//        buffer.moveWriterIndex(to: offset)
//        buffer.writeBytes(data)
//        return .bytesRead(bytesPeeked)
//    }
//
//    @discardableResult
//    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int, allowsEndOfInput: Bool) async throws -> Bool {
//        if try await !advancePeekPosition(length: length, allowsEndOfInput: allowsEndOfInput) {
//            return false
//        }
//        peekBuffer.moveReaderIndex(to: offset)
//        guard let data = peekBuffer.readBytes(length: length) else { return false }
//        buffer.moveWriterIndex(to: peekBufferPosition - length)
//        buffer.writeBytes(data)
//
//        return true
//    }
//
//    func peekFully(to buffer: inout ByteBuffer, offset: Int, length: Int) async throws {
//        try await peekFully(to: &buffer, offset: offset, length: length, allowsEndOfInput: false)
//    }

//    @discardableResult
//    func advancePeekPosition(length: Int, allowsEndOfInput: Bool) async throws -> Bool {
//        var bytesPeeked = peekBufferLength - peekBufferPosition
//        while bytesPeeked < length {
//            bytesPeeked = try await readFromUpstream(
//                target: &peekBuffer,
//                offset: peekBufferPosition, length: length,
//                bytesAlreadyRead: bytesPeeked,
//                allowEndOfInput: allowsEndOfInput
//            )
//            if bytesPeeked == .resultEndOfInput { return false }
//            peekBufferLength = peekBufferPosition + bytesPeeked
//        }
//        peekBufferPosition += length
//        return true
//    }
//
//    func advancePeekPosition(length: Int) async throws {
//        try await advancePeekPosition(length: length, allowsEndOfInput: false)
//    }

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
 
//    private func readFromUpstream(
//        target: inout ByteBuffer,
//        offset: Int, length: Int,
//        bytesAlreadyRead: Int,
//        allowEndOfInput: Bool
//    ) async throws -> Int {
//        executor.assertIsolated()
//        do {
//            let bytesRead = try await dataReader.read(to: &target, offset: offset, length: length)
//            return bytesAlreadyRead + bytesRead
//        } catch {
//            if bytesAlreadyRead == 0 && allowEndOfInput {
//                return .resultEndOfInput
//            }
//            throw error
//        }
//    }
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
