//
//  TimelineWithUpdatedMediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
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
