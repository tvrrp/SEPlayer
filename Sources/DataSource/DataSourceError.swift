//
//  DataSourceError.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//

import Foundation
import SEPlayerCommon

public class DataSourceError: IOError, @unchecked Sendable {
    public let reason: Reason
    private let code: PlaybackErrorCode

    public init(
        reason: Reason,
        message: String = "",
        errorCode: PlaybackErrorCode = .ioUnspecified,
        cause: (any Error)? = nil
    ) {
        self.reason = reason
        code = errorCode
        let cause: (any Error)? = if let cause {
            cause
        } else if case let .customError(error) = reason {
            error
        } else {
            nil
        }
        super.init(message: message, cause: cause)
    }

    public override var errorCode: PlaybackErrorCode { code }

    /// Whether the error, or one it was caused by, is a read that started past the end of the resource.
    public static func isCausedByPositionOutOfRange(_ error: any Error) -> Bool {
        var error: (any Error)? = error
        while let current = error {
            if let dataSourceError = current as? DataSourceError, dataSourceError.reason == .positionOutOfRange {
                return true
            }
            error = (current as? IOError)?.cause
        }
        return false
    }
}

public extension DataSourceError {
    enum Reason: Equatable {
        case alreadyOpened
        case connectionNotOpened
        /// A read started past the end of the resource.
        case positionOutOfRange
        /// The server answered with this status code, outside 2xx.
        case invalidResponseCode(Int)
        /// The resource changed on the server while bytes of its earlier version were read from a cache.
        case resourceChanged
        case customError(any Error)
        case unknown

        public static func == (lhs: Reason, rhs: Reason) -> Bool {
            switch (lhs, rhs) {
            case (.alreadyOpened, .alreadyOpened),
                 (.connectionNotOpened, .connectionNotOpened),
                 (.positionOutOfRange, .positionOutOfRange),
                 (.resourceChanged, .resourceChanged),
                 (.unknown, .unknown):
                true
            case let (.invalidResponseCode(lhs), .invalidResponseCode(rhs)):
                lhs == rhs
            default:
                false
            }
        }
    }
}

/// Thrown when an HTTP server answers with a status code outside 2xx.
public final class InvalidResponseCodeError: DataSourceError, @unchecked Sendable {
    /// The status code of the response.
    public let responseCode: Int
    /// The url of the request.
    public let url: URL?
    /// The header fields of the response.
    public let headerFields: [AnyHashable: Any]

    public init(response: HTTPURLResponse, url: URL?, cause: (any Error)? = nil) {
        responseCode = response.statusCode
        self.url = url
        headerFields = response.allHeaderFields
        super.init(
            reason: .invalidResponseCode(response.statusCode),
            message: "Response code: \(response.statusCode)",
            errorCode: .ioBadHttpStatus,
            cause: cause
        )
    }
}
