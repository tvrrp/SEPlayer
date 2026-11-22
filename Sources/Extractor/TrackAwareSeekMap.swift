//
//  TrackAwareSeekMap.swift
//  SEPlayer
//
//  Created by tvrrp on 09.03.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.TrackAwareSeekMap
//  Copyright (C) 2025 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public protocol TrackAwareSeekMap: SeekMap {
    func isSeekable(trackId: Int) -> Bool
    func getSeekPoints(time: CMTime, trackId: Int?) -> SeekPoints
}
