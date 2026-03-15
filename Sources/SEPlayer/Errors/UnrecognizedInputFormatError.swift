//
//  UnrecognizedInputFormatError.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import Foundation
import SEPlayerCommon
import Extractor

final class UnrecognizedInputFormatError: ParserError, @unchecked Sendable {
    public let url: URL
    public let sniffFailures: [SniffFailure]

    init(message: String, url: URL, sniffFailures: [SniffFailure]) {
        self.url = url
        self.sniffFailures = sniffFailures

        super.init(message: message, contentIsMalformed: false, dataType: .media)
    }

    override func getMessage() -> String? {
        let superMessage = super.getMessage()
        return sniffFailures.isEmpty ? superMessage : superMessage?.appending("\nsniff failures: \(sniffFailures)")
    }
}
