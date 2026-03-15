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

    public static let illegalState = ErrorBuilder(errorDescription: "Illegal state")
}
