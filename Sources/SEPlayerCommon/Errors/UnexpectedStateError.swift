//
//  UnexpectedStateError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

public func checkArgument(
    _ check: @autoclosure () -> Bool,
    _ file: String = #fileID,
    _ line: Int = #line,
    _ funcName: String = #function,
) throws(UnexpectedStateError) {
    if check() == false {
        throw UnexpectedStateError(file: file, line: line, funcName: funcName)
    }
}

public struct UnexpectedStateError: Error {
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
