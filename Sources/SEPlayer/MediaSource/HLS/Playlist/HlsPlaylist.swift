//
//  HlsPlaylist.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//

/// Represents an HLS playlist.
public protocol HlsPlaylist {
    /// The base URL. Used to resolve relative paths.
    var baseUrl: String { get }
    /// The list of tags in the playlist.
    var tags: [String] { get }
    /// Whether the media is formed of independent segments, as defined by the
    /// #EXT-X-INDEPENDENT-SEGMENTS tag.
    var hasIndependentSegments: Bool { get }
}
