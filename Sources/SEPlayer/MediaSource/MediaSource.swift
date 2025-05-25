//
//  MediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

public protocol MediaSource: AnyObject {
    var isSingleWindow: Bool { get }

    func getMediaItem() -> MediaItem
    func getInitialTimeline() -> Timeline?
    func canUpdateMediaItem(new item: MediaItem) -> Bool
    func updateMediaItem(new item: MediaItem)
    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID)
    func enable(delegate: MediaSourceDelegate)
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) -> MediaPeriod
    func release(mediaPeriod: MediaPeriod)
    func disable(delegate: MediaSourceDelegate)
    func releaseSource(delegate: MediaSourceDelegate)
    func continueLoadingRequested(with source: any MediaSource)
}

//protocol MediaSourceEventListener: AnyObject {
//    func loadStarted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
//    func loadCompleted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
//    func loadCancelled(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
//    func loadError(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void, error: Error, wasCancelled: Bool)
//    func formatChanged(windowIndex: Int, mediaPeriodId: MediaPeriodId?, mediaLoadData: Void)
//}

public protocol MediaSourceDelegate: AnyObject {
    func mediaSource(_ source: any MediaSource, sourceInfo refreshed: Timeline)
}

class BaseMediaSource: MediaSource {
    var isSingleWindow: Bool { true }

    final var isEnabled: Bool {
        assert(queue.isCurrent())
        return mediaSourceDelegates.count != 0
    }

    final var playerId: UUID? {
        get { assert(queue.isCurrent()); return _playerId }
        set { assert(queue.isCurrent()); _playerId = newValue }
    }

    private let queue: Queue
    private let mediaSourceDelegates: MulticastDelegate<MediaSourceDelegate>

    private var _playerId: UUID?
    private var _timeline: Timeline?

    init(queue: Queue) {
        self.queue = queue
        mediaSourceDelegates = MulticastDelegate<MediaSourceDelegate>(isThreadSafe: false)
    }

    func getMediaItem() -> MediaItem { fatalError("To override") }
    func getInitialTimeline() -> Timeline? { nil }
    func canUpdateMediaItem(new item: MediaItem) -> Bool { false }
    func updateMediaItem(new item: MediaItem) {}
    func prepareSourceInternal(mediaTransferListener: TransferListener?) { fatalError("To override") }
    func releaseSourceInternal() { fatalError("To override") }
    func updateMediaItem() { fatalError("To override") }
    func enableInternal() { fatalError("To override") }
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) -> MediaPeriod {
        fatalError("To override")
    }
    func release(mediaPeriod: any MediaPeriod) { fatalError("To override") }
    func disableInternal() { fatalError("To override") }
    func continueLoadingRequested(with source: any MediaSource) { fatalError("To override") }

    final func refreshSourceInfo(timeline: Timeline) {
        assert(queue.isCurrent())
        self._timeline = timeline
        mediaSourceDelegates.invokeDelegates { $0.mediaSource(self, sourceInfo: timeline) }
    }

    final func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) {
        assert(queue.isCurrent())
        self._playerId = playerId
        mediaSourceDelegates.addDelegate(delegate)
        prepareSourceInternal(mediaTransferListener: mediaTransferListener)
        if let _timeline {
            delegate.mediaSource(self, sourceInfo: _timeline)
        }
    }

    final func enable(delegate: MediaSourceDelegate) {
        let wasDisabled = mediaSourceDelegates.count == 0
        mediaSourceDelegates.addDelegate(delegate)
        if wasDisabled {
            enableInternal()
        }
    }

    final func disable(delegate: MediaSourceDelegate) {
        let wasEnabled = mediaSourceDelegates.count > 0
        mediaSourceDelegates.removeDelegate(delegate)
        if wasEnabled && mediaSourceDelegates.count == 0 {
            disableInternal()
        }
    }

    final func releaseSource(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        mediaSourceDelegates.removeDelegate(delegate)
        if mediaSourceDelegates.count == 0 {
            _timeline = nil
            playerId = nil
            releaseSourceInternal()
        }
    }
}
