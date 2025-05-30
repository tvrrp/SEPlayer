//
//  Error+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

import Foundation.FoundationErrors

struct ErrorBuilder: Error, LocalizedError {
    let errorDescription: String?

    static let illegalState = ErrorBuilder(errorDescription: "Illegal state")
}
