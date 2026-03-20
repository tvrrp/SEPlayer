//
//  Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

public protocol Extractor: AnyObject {
    func initialize(output: ExtractorOutput, isolation: isolated any Actor) throws
    func shiff(input: ExtractorInput, isolation: isolated any Actor) async throws -> Bool
    func getSniffFailureDetails(isolation: isolated any Actor) -> [SniffFailure]
    func read(input: ExtractorInput, isolation: isolated any Actor) async throws -> ExtractorReadResult
    func seek(to position: Int, time: CMTime, isolation: isolated any Actor) throws
    func release(isolation: isolated any Actor)
}

public extension Extractor {
    func getSniffFailureDetails(isolation: isolated any Actor) -> [SniffFailure] { [] }
    func release(isolation: isolated any Actor) {}
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
