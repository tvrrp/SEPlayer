//
//  Optional+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

extension Optional {
    func checkNotNil(_ error: Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }

    mutating func withTransform<T>(_ transform: (inout Wrapped) throws -> T) rethrows -> T? {
        if var value = self {
            let result = try transform(&value)
            self = value
            return result
        }
        return nil
    }
}
