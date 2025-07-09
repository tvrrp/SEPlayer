//
//  ParserException.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 27.06.2025.
//

struct ParserException: Error {
    let message: String?
    let cause: Error?
    let contentIsMalformed: Bool
    let dataType: String?

    init(malformedContainer message: String, cause: Error? = nil) {
        self.init(message: message, cause: cause, contentIsMalformed: true)
    }

    init(unsupportedContainerFeature message: String) {
        self.init(message: message)
    }

    private init(
        message: String? = nil,
        cause: Error? = nil,
        contentIsMalformed: Bool = false,
        dataType: String? = nil
    ) {
        self.message = message
        self.cause = cause
        self.contentIsMalformed = contentIsMalformed
        self.dataType = dataType
    }
}
