//
//  DataSourceError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import SEPlayerCommon

public class DataSourceError: IOError, @unchecked Sendable {
    public let reason: Reason

    public init(reason: Reason, message: String = "") {
        self.reason = reason
        let cause: (any Error)? = if case let .customError(error) = reason {
            error
        } else {
            nil
        }
        super.init(message: message, cause: cause)
    }
}

public extension DataSourceError {
    enum Reason {
        case alreadyOpened
        case connectionNotOpened
        case customError(any Error)
        case unknown
    }
}
