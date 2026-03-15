//
//  EndOfFileError.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//

public final class EndOfFileError: IOError, @unchecked Sendable {
    public init() {
        super.init(message: nil, cause: nil)
    }
}
