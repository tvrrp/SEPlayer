//
//  Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public protocol Extractor: AnyObject {
    func shiff(input: ExtractorInput) throws
    func read(input: ExtractorInput) throws -> ExtractorReadResult
    func seek(to position: Int, timeUs: Int64)
    func release()
}

public extension Extractor {
    func getSniffFailureDetails() -> [SniffFailure] { [] }
    func release() {}
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
