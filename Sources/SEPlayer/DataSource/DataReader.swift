//
//  DataReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

public protocol DataReader {
    func read(
        to buffer: ByteBuffer,
        offset: Int,
        length: Int,
        completionQueue: Queue,
        completion: @escaping (Result<(ByteBuffer, Int), Error>) -> Void
    )

    func read(
        allocation: Allocation,
        offset: Int,
        length: Int,
        completionQueue: Queue,
        completion: @escaping (Result<(Int), Error>) -> Void
    )
}

public enum DataReaderError: Error {
    case endOfInput
    case connectionNotOpened
    case wrongURLResponce
}
