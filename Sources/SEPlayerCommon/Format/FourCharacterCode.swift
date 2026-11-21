//
//  FourCharacterCode.swift
//  SEPlayer
//

import Foundation

/// A code of four characters, as ISO base media files name their boxes and codecs: `avcC`, `mp4a`.
public struct FourCharacterCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
                                 CustomStringConvertible {
    public let rawValue: UInt32

    /// The characters of the code, read as Mac OS Roman, as QuickTime wrote them.
    public var description: String {
        let bytes = (0 ..< 4).map { UInt8(truncatingIfNeeded: rawValue >> (24 - 8 * $0)) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The code of the first four characters of `characters`.
    public init(_ characters: String) {
        rawValue = (characters.data(using: .macOSRoman) ?? Data()).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}
