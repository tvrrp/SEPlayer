//
//  LoadingInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.LoadingInfo
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public struct LoadingInfo: Hashable {
    let playbackPosition: CMTime
    let playbackSpeed: Float
    let lastRebufferRealtime: CMTime

    func rebufferedSince(realtime: CMTime) -> Bool {
        lastRebufferRealtime.isValid
            && realtime.isValid
            && lastRebufferRealtime >= realtime
    }
}
