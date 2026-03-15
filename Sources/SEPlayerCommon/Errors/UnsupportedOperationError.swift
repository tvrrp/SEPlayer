//
//  UnsupportedOperationError.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

public struct UnsupportedOperationError: Error {
    public let file: String
    public let line: Int
    public let funcName: String

    public init(
        file: String = #fileID,
        line: Int = #line,
        funcName: String = #function
    ) {
        self.file = file
        self.line = line
        self.funcName = funcName
    }
}
