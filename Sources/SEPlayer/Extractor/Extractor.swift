//
//  Extractor.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

protocol Extractor: AnyObject {
    func read(input: ExtractorInput, completion: @escaping (ExtractorReadResult) -> Void)
    func seek(to position: Int, time: Int64)
    func release()
}

extension Extractor {
    func release() {}
}

enum ExtractorReadResult: Equatable {
    case continueRead
    case endOfInput
    case seek(offset: Int)
    case error(Error)

    static func == (lhs: ExtractorReadResult, rhs: ExtractorReadResult) -> Bool {
        switch (lhs, rhs) {
        case (.continueRead, .continueRead):
            return true
        case (.endOfInput, .endOfInput):
            return true
        case (.seek(_), .seek(_)):
            return true
        case (.error(_), .error(_)):
            return true
        default:
            return false
        }
    }
}
