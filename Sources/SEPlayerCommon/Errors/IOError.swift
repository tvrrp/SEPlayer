//
//  IOError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

open class IOError: Error, @unchecked Sendable {
    public let message: String?
    public let cause: Error?

    public init(message: String?, cause: Error?) {
        self.message = message
        self.cause = cause
    }

    open func getMessage() -> String? {
        var description = String()
        if let message {
            description.append(message)
        }
        description.append("\n")
        if let cause {
            description.append("\(cause)")
        }

        return description
    }
}

extension IOError: CustomStringConvertible {
    public var description: String { getMessage() ?? "" }
}
