//
//  HlsPlaylistParser.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//

import Foundation

protocol FakeReader {
    func readLine() async throws -> String?
}

final class HlsPlaylistParser {
//    private static let regexFrameRate = NSRegularExpression(pattern: "FRAME-RATE=([\d\.]+)\b")
    func parse(url: URL, stream: FakeReader) async throws {

    }

    private func parseMultivariantPlaylist(
        iterator: AsyncThrowingStream<String, Error>,
        playlistUrl: String,
    ) async throws {
        for try await line in iterator {
            
        }
    }
}
