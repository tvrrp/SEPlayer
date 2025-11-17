//
//  MediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public protocol MediaSource: AnyObject {
    var isSingleWindow: Bool { get }

    func getMediaItem() -> MediaItem
    func getInitialTimeline() -> Timeline?
    func canUpdateMediaItem(new item: MediaItem) -> Bool
    func updateMediaItem(new item: MediaItem) throws
    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws
    func enable(delegate: MediaSourceDelegate)
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) throws -> MediaPeriod
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
    func mediaSource(_ source: any MediaSource, sourceInfo refreshed: Timeline) throws
}

class BaseMediaSource: MediaSource {
    var isSingleWindow: Bool { true }

    final var isEnabled: Bool {
        assert(queue.isCurrent())
        return enabledMediaSourceDelegates.count != 0
    }

    final var playerId: UUID? {
        get { assert(queue.isCurrent()); return _playerId }
        set { assert(queue.isCurrent()); _playerId = newValue }
    }

    private let queue: Queue
    private let mediaSourceDelegates: MulticastDelegate<MediaSourceDelegate>
    private let enabledMediaSourceDelegates: NSHashTable<AnyObject>

    private var didPrepare: Bool = false
    private var _playerId: UUID?
    private var _timeline: Timeline?

    init(queue: Queue) {
        self.queue = queue
        mediaSourceDelegates = MulticastDelegate<MediaSourceDelegate>(isThreadSafe: false)
        enabledMediaSourceDelegates = NSHashTable()
    }

    func getMediaItem() -> MediaItem { fatalError("To override") }
    func getInitialTimeline() -> Timeline? { nil }
    func canUpdateMediaItem(new item: MediaItem) -> Bool { false }
    func updateMediaItem(new item: MediaItem) throws {}
    func prepareSourceInternal(mediaTransferListener: TransferListener?) throws { fatalError("To override") }
    func releaseSourceInternal() {}
    func updateMediaItem() { fatalError("To override") }
    func enableInternal() {}
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) throws -> MediaPeriod {
        fatalError("To override")
    }
    func release(mediaPeriod: MediaPeriod) { fatalError("To override") }
    func disableInternal() {}
    func continueLoadingRequested(with source: any MediaSource) { fatalError("To override") }

    final func refreshSourceInfo(timeline: Timeline) throws {
        assert(queue.isCurrent())
        self._timeline = timeline
        try mediaSourceDelegates.invokeDelegates { try $0.mediaSource(self, sourceInfo: timeline) }
    }

    final func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws {
        assert(queue.isCurrent())
        self._playerId = playerId
        mediaSourceDelegates.addDelegate(delegate)
        if !didPrepare {
            enabledMediaSourceDelegates.add(delegate)
            try prepareSourceInternal(mediaTransferListener: mediaTransferListener)
            didPrepare = true
        } else if let _timeline {
            enable(delegate: delegate)
            try delegate.mediaSource(self, sourceInfo: _timeline)
        }
    }

    final func enable(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        let wasDisabled = enabledMediaSourceDelegates.count == 0
        enabledMediaSourceDelegates.add(delegate)
        if wasDisabled {
            enableInternal()
        }
    }

    final func disable(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        let wasEnabled = enabledMediaSourceDelegates.count > 0
        enabledMediaSourceDelegates.remove(delegate)
        if wasEnabled && enabledMediaSourceDelegates.count == 0 {
            disableInternal()
        }
    }

    final func releaseSource(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        mediaSourceDelegates.removeDelegate(delegate)
        if mediaSourceDelegates.count == 0 {
            didPrepare = false
            _timeline = nil
            playerId = nil
            enabledMediaSourceDelegates.removeAllObjects()
            releaseSourceInternal()
        } else {
            disable(delegate: delegate)
        }
    }
}
