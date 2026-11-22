//
//  ParserError.swift
//  SEPlayer
//
//  Created by tvrrp on 25.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.ParserException
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

open class ParserError: IOError, @unchecked Sendable {
    public let contentIsMalformed: Bool
    public let dataType: DataType

    public init(
        message: String? = nil,
        cause: Error? = nil,
        contentIsMalformed: Bool,
        dataType: DataType
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

    open override var errorCode: PlaybackErrorCode {
        switch (dataType, contentIsMalformed) {
        case (.manifest, true): .parsingManifestMalformed
        case (.manifest, false): .parsingManifestUnsupported
        case (_, true): .parsingContainerMalformed
        case (_, false): .parsingContainerUnsupported
        }
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
