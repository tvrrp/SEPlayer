//
//  HlsPlaylist.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.hls.playlist.HlsPlaylist
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
