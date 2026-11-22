//
//  TimelineWithUpdatedMediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.TimelineWithUpdatedMediaItem
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

final class TimelineWithUpdatedMediaItem: ForwardingTimeline, @unchecked Sendable {
    private let updatedMediaItem: MediaItem

    init(timeline: any Timeline, updatedMediaItem: MediaItem) {
        self.updatedMediaItem = updatedMediaItem
        super.init(timeline: timeline)
    }

    override func getWindow(windowIndex: Int, window: Window, defaultPositionProjection: CMTime) -> Window {
        super.getWindow(windowIndex: windowIndex, window: window, defaultPositionProjection: defaultPositionProjection)
        window.mediaItem = updatedMediaItem
        return window
    }
}
