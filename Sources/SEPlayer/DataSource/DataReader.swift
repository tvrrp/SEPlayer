//
//  DataReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

public protocol DataReader {
    func read(
        to buffer: inout ByteBuffer,
        offset: Int,
        length: Int,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
    func read(
        allocation: Allocation,
        offset: Int,
        length: Int,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult
}

public enum DataReaderReadResult {
    case success(amount: Int)
    case endOfInput
}

public enum DataReaderError: Error {
    case endOfInput
    case connectionNotOpened
    case wrongURLResponce
}
