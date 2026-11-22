//
//  StreamKey.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.StreamKey
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

/// A key for a subset of media that can be separately loaded (a "stream").
///
/// The stream key consists of a period index, a group index within the period and a stream index within the group.
/// The interpretation of these indices depends on the type of media for which the stream key is used. Note that they
/// are not the same as track group and track indices, because multiple tracks can be multiplexed into a single
/// stream.
///
/// Application code should not generally attempt to build stream key instances directly. Instead, they are created
/// by media-specific helpers.
public struct StreamKey: Hashable, Comparable, Sendable {
    /// The period index.
    public let periodIndex: Int
    /// The group index.
    public let groupIndex: Int
    /// The stream index.
    public let streamIndex: Int

    /// Creates an instance with `periodIndex` set to 0.
    ///
    /// - Parameters:
    ///   - groupIndex: The group index.
    ///   - streamIndex: The stream index.
    public init(groupIndex: Int, streamIndex: Int) {
        self.init(periodIndex: 0, groupIndex: groupIndex, streamIndex: streamIndex)
    }

    /// Creates an instance.
    ///
    /// - Parameters:
    ///   - periodIndex: The period index.
    ///   - groupIndex: The group index.
    ///   - streamIndex: The stream index.
    public init(periodIndex: Int, groupIndex: Int, streamIndex: Int) {
        self.periodIndex = periodIndex
        self.groupIndex = groupIndex
        self.streamIndex = streamIndex
    }

    public static func < (lhs: StreamKey, rhs: StreamKey) -> Bool {
        (lhs.periodIndex, lhs.groupIndex, lhs.streamIndex) < (rhs.periodIndex, rhs.groupIndex, rhs.streamIndex)
    }
}
