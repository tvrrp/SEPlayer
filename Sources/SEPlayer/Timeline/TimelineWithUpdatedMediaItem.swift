//
//  TimelineWithUpdatedMediaItem.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

final class TimelineWithUpdatedMediaItem: ForwardingTimeline, @unchecked Sendable {
    private let updatedMediaItem: MediaItem

    init(timeline: any Timeline, updatedMediaItem: MediaItem) {
        self.updatedMediaItem = updatedMediaItem
        super.init(timeline: timeline)
    }

    override func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
        window = super.getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: defaultPositionProjectionUs)
        window.mediaItem = updatedMediaItem
        return window
    }
}
