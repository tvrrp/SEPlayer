//
//  Error+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//

import Foundation

struct ErrorBuilder: Error, LocalizedError {
    var errorDescription: String?

    static var illegalState = ErrorBuilder(errorDescription: "Illegal state")
}
