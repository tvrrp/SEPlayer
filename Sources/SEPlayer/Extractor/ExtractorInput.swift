//
//  ExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

enum ExtractorInputReadResult {
    case bytesRead(ByteBuffer, Int)
    case endOfInput
}

protocol ExtractorInput: DataReader {
    var queue: Queue { get }

    func read(to buffer: ByteBuffer, offset: Int, length: Int, completion: @escaping (ExtractorInputReadResult) -> Void)
    func skip(length: Int, completion: @escaping (DataReaderError?) -> Void)

    func getPosition() -> Int
    func getLength() -> Int
}

extension ExtractorInput {
    func read(to buffer: ByteBuffer, offset: Int, length: Int, completionQueue: Queue, completion: @escaping (Result<(ByteBuffer, Int), Error>) -> Void) {
        queue.async {
            read(to: buffer, offset: offset, length: length) { result in
                switch result {
                case let .bytesRead(buffer, bytesRead):
                    completionQueue.async { completion(.success((buffer, bytesRead))) }
                case .endOfInput:
                    completionQueue.async { completion(.failure(DataReaderError.endOfInput)) }
                }
            }
        }
    }
}
