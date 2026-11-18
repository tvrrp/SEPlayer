//
//  Optional+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

public extension Optional {
    @inlinable
    @discardableResult
    func checkNotNil(_ error: Error) throws -> Wrapped {
        guard let self else {
            throw error
        }
        return self
    }

    @inlinable
    @discardableResult
    func checkNotNil(
        _ file: String = #fileID,
        _ line: Int = #line,
        _ funcName: String = #function
    ) throws(UnexpectedStateError) -> Wrapped {
        guard let self else {
            throw UnexpectedStateError(file: file, line: line, funcName: funcName)
        }
        return self
    }

    @inlinable
    mutating func withTransform<T>(_ transform: (inout Wrapped) throws -> T) rethrows -> T? {
        if var value = self {
            let result = try transform(&value)
            self = value
            return result
        }
        return nil
    }
}
