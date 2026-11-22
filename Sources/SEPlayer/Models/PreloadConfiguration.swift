//
//  PreloadConfiguration.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 16.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.ExoPlayer
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public struct PreloadConfiguration: Equatable {
    /// How much of the next item to load ahead; `.invalid` doesn't preload.
    public let targetPreloadDuration: CMTime

    public init(targetPreloadDuration: CMTime) {
        self.targetPreloadDuration = targetPreloadDuration
    }

    public static let `default` = PreloadConfiguration(targetPreloadDuration: .invalid)
}
