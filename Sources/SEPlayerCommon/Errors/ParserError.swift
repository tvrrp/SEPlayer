//
//  ParserError.swift
//  SEPlayer
//
//  Created by tvrrp on 25.02.2026.
//

open class ParserError: IOError, @unchecked Sendable {
    public let contentIsMalformed: Bool
    public let dataType: DataType

    public init(
        message: String? = nil,
        cause: Error? = nil,
        contentIsMalformed: Bool,
        dataType: DataType,
    ) {
        self.contentIsMalformed = contentIsMalformed
        self.dataType = dataType
        super.init(message: message, cause: cause)
    }

    public static func createForMalformedDataOfUnknownType(
        message: String? = nil,
        cause: Error? = nil
    ) -> ParserError {
        ParserError(message: message, cause: cause, contentIsMalformed: true, dataType: .unknown)
    }

    public static func createForMalformedContainer(
        message: String? = nil,
        cause: Error? = nil
    ) -> ParserError {
        ParserError(message: message, cause: cause, contentIsMalformed: true, dataType: .media)
    }

    public static func createForMalformedManifest(
        message: String? = nil,
        cause: Error? = nil
    ) -> ParserError {
        ParserError(message: message, cause: cause, contentIsMalformed: true, dataType: .manifest)
    }

    public static func createForManifestWithUnsupportedFeature(
        message: String? = nil,
        cause: Error? = nil
    ) -> ParserError {
        ParserError(message: message, cause: cause, contentIsMalformed: false, dataType: .manifest)
    }

    public static func createForUnsupportedContainerFeature(
        message: String? = nil,
        cause: Error? = nil
    ) -> ParserError {
        ParserError(message: message, cause: cause, contentIsMalformed: false, dataType: .media)
    }

    open override func getMessage() -> String? {
        var string = String()
        if let message {
            string += (message + " ")
        }
        string += "contentIsMalformed = \(contentIsMalformed)" + " "
        string += "dataType = \(dataType)"
        return string
    }
}
