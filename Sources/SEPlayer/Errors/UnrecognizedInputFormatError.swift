//
//  UnrecognizedInputFormatError.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//

import Extractor
import Foundation
import SEPlayerCommon

final class UnrecognizedInputFormatError: ParserError, @unchecked Sendable {
    let url: URL
    let sniffFailures: [SniffFailure]

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
