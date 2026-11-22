//
//  SelectionFlags.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.C
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

/// Track selection flags.
@frozen
public struct SelectionFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Indicates that the track should be selected if user preferences do not state otherwise.
    public static let `default` = SelectionFlags(rawValue: 1)
    /// Indicates that the track should be selected if its language matches the language of the selected audio track
    /// and user preferences do not state otherwise. Only applies to text tracks.
    ///
    /// Tracks with this flag generally provide translation for elements that don't match the declared language of the
    /// selected audio track (e.g. speech in an alien language). See [Netflix's summary](https://partnerhelp.netflixstudios.com/hc/en-us/articles/217558918)
    /// for more info.
    public static let forced = SelectionFlags(rawValue: 1 << 1)
    /// Indicates that the player may choose to play the track in absence of an explicit user preference.
    public static let autoselect = SelectionFlags(rawValue: 1 << 2)
}
