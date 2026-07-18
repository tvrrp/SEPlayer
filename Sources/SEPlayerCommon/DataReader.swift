//
//  DataReader.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.05.2025.
//

import CoreMedia

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

@frozen public enum DataReaderReadResult: Equatable {
    case success(amount: Int)
    case endOfInput
}

public protocol DataReader2 {
    func read(range: Range<Int>, isolation: isolated any Actor) async throws -> CMBlockBuffer
}

public protocol DataReader3 {
    func read(range: Range<Int>) async throws -> CMBlockBuffer
}
