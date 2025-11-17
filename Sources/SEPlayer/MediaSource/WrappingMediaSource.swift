//
//  WrappingMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import ObjectiveC

class WrappingMediaSource: CompositeMediaSource<NSObject> {
    let mediaSource: MediaSource
    private static let childSourceId = NSObject()

    init(queue: Queue, mediaSource: MediaSource) {
        self.mediaSource = mediaSource
        super.init(queue: queue)
    }

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) throws {
        try super.prepareSourceInternal(mediaTransferListener: mediaTransferListener)
        try prepareSourceInternal()
    }

    func prepareSourceInternal() throws { fatalError("To override") }
    override func getInitialTimeline() -> Timeline? { mediaSource.getInitialTimeline() }
    override var isSingleWindow: Bool { mediaSource.isSingleWindow }

    override func getMediaItem() -> MediaItem {
        mediaSource.getMediaItem()
    }

    override func canUpdateMediaItem(new item: MediaItem) -> Bool {
        mediaSource.canUpdateMediaItem(new: item)
    }

    override func updateMediaItem(new item: MediaItem) throws { try mediaSource.updateMediaItem(new: item) }

    override func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: Int64) throws -> any MediaPeriod {
        try mediaSource.createPeriod(id: id, allocator: allocator, startPosition: startPosition)
    }

    override func release(mediaPeriod: MediaPeriod) {
        mediaSource.release(mediaPeriod: mediaPeriod)
    }

    override final func onChildSourceInfoRefreshed(
        childSourceId: NSObject,
        mediaSource: MediaSource,
        newTimeline: Timeline
    ) throws {
        try onChildSourceInfoRefreshed(newTimeline: newTimeline)
    }

    func onChildSourceInfoRefreshed(newTimeline: Timeline) throws {
        try refreshSourceInfo(timeline: newTimeline)
    }

    override final func getMediaPeriodIdForChildMediaPeriodId(
        childSourceId: NSObject,
        mediaPeriodId: MediaPeriodId
    ) -> MediaPeriodId {
        mediaPeriodIdForChild(mediaPeriodId: mediaPeriodId)
    }

    func mediaPeriodIdForChild(mediaPeriodId: MediaPeriodId) -> MediaPeriodId { mediaPeriodId }

    final func prepareChildSource() throws {
        try prepareChildSource(id: Self.childSourceId, mediaSource: mediaSource)
    }

    final func enableChildSource() {
        enableChildSource(id: Self.childSourceId)
    }

    final func disableChildSource() {
        disableChildSource(id: Self.childSourceId)
    }

    final func releaseChildSource() {
        releaseChildSource(id: Self.childSourceId)
    }
}
