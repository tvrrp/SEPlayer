//
//  UnrecognizedInputFormatError.swift
//  SEPlayer
//
//  Created by tvrrp on 10.03.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.UnrecognizedInputFormatException
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
