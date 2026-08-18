//
//  ExtractorInput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol ExtractorInput: DataReader {
    @discardableResult
    func read(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer

    @discardableResult
    func readFully(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool)

    @discardableResult
    func skip(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) throws -> Bool

    func peek(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer

    func peekFully(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) async throws -> (buffer: CMBlockBuffer, isEndOfInput: Bool)

    func advancePeekPosition(length: Int, allowEndOfInput: Bool, _ isolation: isolated any Actor) throws

    func advancePeekPosition(length: Int, _ isolation: isolated any Actor) throws

    func resetPeekPosition(_ isolation: isolated any Actor)

    func getPeekPosition(_ isolation: isolated any Actor) -> Int

    func getPosition(_ isolation: isolated any Actor) -> Int

    func getLength(_ isolation: isolated any Actor) -> Int?

    func set<E: Error>(retryPosition: Int, using error: E, _ isolation: isolated any Actor) throws(E)
}

public extension ExtractorInput {
    @discardableResult
    func readFully(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer {
        let (blockBuffer, _) = try await readFully(length: length, allowEndOfInput: false, isolation)
        return blockBuffer
    }

    func skip(length: Int, _ isolation: isolated any Actor) throws {
        try skip(length: length, allowEndOfInput: false, isolation)
    }

    func peekFully(length: Int, _ isolation: isolated any Actor) async throws -> CMBlockBuffer {
        try await peekFully(length: length, allowEndOfInput: false, isolation).buffer
    }
}
