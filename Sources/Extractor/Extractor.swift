//
//  Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol Extractor: AnyObject {
    func initialize(output: any ExtractorOutput, isolation: isolated any Actor) throws
    func shiff(input: any ExtractorInput, isolation: isolated any Actor) async throws -> Bool
    func getSniffFailureDetails(isolation: isolated any Actor) -> [any SniffFailure]
    func read(input: any ExtractorInput, isolation: isolated any Actor) async throws -> ExtractorReadResult
    func seek(to position: Int, time: CMTime, isolation: isolated any Actor) throws
    func release(isolation: isolated any Actor)
    func getUnderlyingImplementation() -> any Extractor
}

public extension Extractor {
    func getSniffFailureDetails(isolation: isolated any Actor) -> [any SniffFailure] { [] }
    func release(isolation: isolated any Actor) {}
    func getUnderlyingImplementation() -> any Extractor { self }
}

public protocol Extractor2: AnyObject {
    func initialize(output: any ExtractorOutput2, isolation: isolated any Actor) throws
    func shiff(input: any ExtractorInput2, isolation: isolated any Actor) async throws -> Bool
    func getSniffFailureDetails(isolation: isolated any Actor) -> [any SniffFailure]
    func read(input: any ExtractorInput2, isolation: isolated any Actor) async throws -> ExtractorReadResult
    func seek(to position: Int, time: CMTime, isolation: isolated any Actor) throws
    func release(isolation: isolated any Actor)
    func getUnderlyingImplementation() -> any Extractor2
}

public extension Extractor2 {
    func getSniffFailureDetails(isolation: isolated any Actor) -> [any SniffFailure] { [] }
    func release(isolation: isolated any Actor) {}
    func getUnderlyingImplementation() -> any Extractor2 { self }
}

public enum ExtractorReadResult: Equatable {
    case continueRead
    case endOfInput
    case seek(offset: Int)

    public static func == (lhs: ExtractorReadResult, rhs: ExtractorReadResult) -> Bool {
        switch (lhs, rhs) {
        case (.continueRead, .continueRead):
            return true
        case (.endOfInput, .endOfInput):
            return true
        case (.seek(_), .seek(_)):
            return true
        default:
            return false
        }
    }
}
