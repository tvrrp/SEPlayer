//
//  Error+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

import Foundation.FoundationErrors

// TODO: remove
public struct ErrorBuilder: Error, LocalizedError {
    public let errorDescription: String?

    public init(errorDescription: String?) {
        self.errorDescription = errorDescription
    }

    /// An error of a state the code can't go on from, with where it was thrown.
    public static func illegalState(
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> ErrorBuilder {
        ErrorBuilder(errorDescription: "Illegal state at \(file):\(line) in \(function)")
    }
}
