//
//  Task+Extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

extension Task where Success == Never, Failure == Never {
    static func sleep(milliseconds duration: UInt64) async throws {
        try await Task.sleep(nanoseconds: duration * 1_000_000)
    }
}
