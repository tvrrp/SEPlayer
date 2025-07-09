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

    init(queue: Queue, mediaSource: MediaSource, mediaItem: MediaItem) {
        self.mediaSource = mediaSource
        super.init(queue: queue)
    }

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) {
        super.prepareSourceInternal(mediaTransferListener: mediaTransferListener)
        prepareSourceInternal()
    }

    func prepareSourceInternal() { fatalError("To override") }
    override func getInitialTimeline() -> Timeline? { mediaSource.getInitialTimeline() }
    override var isSingleWindow: Bool { mediaSource.isSingleWindow }

    override func getMediaItem() -> MediaItem {
        mediaSource.getMediaItem()
    }

    override func canUpdateMediaItem(new item: MediaItem) -> Bool {
        mediaSource.canUpdateMediaItem(new: item)
    }

    override func updateMediaItem(new item: MediaItem) { mediaSource.updateMediaItem(new: item) }

    override func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: Int64) -> any MediaPeriod {
        mediaSource.createPeriod(id: id, allocator: allocator, startPosition: startPosition)
    }

    override func release(mediaPeriod: MediaPeriod) {
        mediaSource.release(mediaPeriod: mediaPeriod)
    }

    override final func onChildSourceInfoRefreshed(childSourceId: NSObject, mediaSource: MediaSource, newTimeline: Timeline) {
        onChildSourceInfoRefreshed(newTimeline: newTimeline)
    }

    func onChildSourceInfoRefreshed(newTimeline: Timeline) {
        refreshSourceInfo(timeline: newTimeline)
    }

    override final func getMediaPeriodIdForChildMediaPeriodId(
        childSourceId: NSObject,
        mediaPeriodId: MediaPeriodId
    ) -> MediaPeriodId {
        mediaPeriodIdForChild(mediaPeriodId: mediaPeriodId)
    }

    func mediaPeriodIdForChild(mediaPeriodId: MediaPeriodId) -> MediaPeriodId { mediaPeriodId }

    final func prepareChildSource() {
        prepareChildSource(id: Self.childSourceId, mediaSource: mediaSource)
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
