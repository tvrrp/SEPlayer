//
//  Endianness.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.11.2026.
//

/// The order of the bytes of an integer in memory or in a file.
public enum Endianness: Sendable {
    /// The most significant byte first.
    case big
    /// The least significant byte first.
    case little
}
