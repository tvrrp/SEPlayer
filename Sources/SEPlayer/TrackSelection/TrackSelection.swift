//
//  TrackSelection.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.trackselection.TrackSelection
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

@frozen
public enum TrackSelectionType {
    case unset
    case customBase
}

public protocol TrackSelection {
    var type: TrackSelectionType { get }
    var trackGroup: TrackGroup { get }
    var length: Int { get }

    func format(for index: Int) -> AnyFormat
    func indexInTrackGroup(_ index: Int) -> Int?
    func indexOf(format: AnyFormat) -> Int?
    func indexOf(indexInTrackGroup: Int) -> Int?
}

public extension TrackSelection {
    func format(for index: Int) -> AnyFormat {
        trackGroup[index]
    }
}
