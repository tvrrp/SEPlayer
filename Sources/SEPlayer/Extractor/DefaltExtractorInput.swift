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

    private var position: Int
    let queue: Queue

    init(dataReader: DataReader, queue: Queue, range: NSRange? = nil) {
        self.dataReader = dataReader
        self.position = range?.location ?? 0
        self.streamLength = range?.length ?? 0
        self.queue = queue
    }

    func read(to buffer: ByteBuffer, offset: Int, length: Int, completion: @escaping (ExtractorInputReadResult) -> Void) {
        assert(queue.isCurrent())

        func completeTask(buffer: ByteBuffer, bytesRead: Int) {
            commitBytesRead(bytesRead)

            if bytesRead != .resultEndOfInput {
                completion(.bytesRead(buffer, bytesRead))
            } else {
                completion(.endOfInput)
            }
        }

        readFromUpstream(target: buffer, offset: offset, length: length, bytesAlreadyRead: 0, allowEndOfInput: true) { result in
            switch result {
            case let .success((buffer, bytesRead)):
                completeTask(buffer: buffer, bytesRead: bytesRead)
            case .failure(_):
                completeTask(buffer: buffer, bytesRead: 0)
            }
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

        func completeTask(bytesSkipped: Int) {
            commitBytesRead(bytesSkipped)

            if bytesSkipped != .resultEndOfInput {
                completion(nil)
            } else {
                completion(.endOfInput)
            }
        }

        readFromUpstream(target: ByteBuffer(), offset: 0, length: length, bytesAlreadyRead: 0, allowEndOfInput: true) { result in
            switch result {
            case let .success((_, bytesRead)):
                completeTask(bytesSkipped: bytesRead)
            case .failure(_):
                completeTask(bytesSkipped: 0)
            }
        }
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
    static let resultEndOfInput: Int = -1

    func clamp(range: Range<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
