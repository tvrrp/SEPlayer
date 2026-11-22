//
//  AdPlaybackState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.11.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.common.AdPlaybackState
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia

public struct AdPlaybackState: Hashable, Sendable {
    public static let none = AdPlaybackState(
        contentDuration: .invalid
    )

    public private(set) var contentDuration: CMTime

    init(adGroupTimes: [CMTime]) {
        contentDuration = .invalid
    }

    init(contentDuration: CMTime) {
        self.contentDuration = contentDuration
    }

    func withContentDuration(_ contentDuration: CMTime) -> Self {
        var copy = self
        copy.contentDuration = contentDuration
        return self
    }
}
