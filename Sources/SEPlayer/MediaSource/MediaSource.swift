//
//  MediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

protocol MediaSource {
    var mediaItem: MediaItem? { get }
    var isSingleWindow: Bool { get }

    func addEventListener(_ listener: MediaSourceEventListener)
    func removeEventListener(_ listener: MediaSourceEventListener)
    func getInitialTimeline() -> Timeline?
    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID)
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: CMTime,
        loadCondition: LoadConditionCheckable,
        mediaSourceEventDelegate: MediaSourceEventListener
    ) -> MediaPeriod
    func release(mediaPeriod: MediaPeriod)
    func continueLoadingRequested(with source: any MediaSource)
}

extension MediaSource {
    var mediaItem: MediaItem? { nil }
    var isSingleWindow: Bool { true }

    func getInitialTimeline() -> Timeline? { nil }
}

struct MediaPeriodId: Hashable {
    let periodId: UUID
    let windowSequenceNumber: Int
}

protocol MediaSourceEventListener: AnyObject {
    func loadStarted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
    func loadCompleted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
    func loadCancelled(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void)
    func loadError(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void, error: Error, wasCancelled: Bool)
    func formatChanged(windowIndex: Int, mediaPeriodId: MediaPeriodId?, mediaLoadData: Void)
}

protocol MediaSourceDelegate: AnyObject {
    func mediaSource(_ source: any MediaSource, sourceInfo refreshed: Timeline?)
}

class BaseMediaSource: MediaSource {
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
    private let mediaSourceEventListeners: MulticastDelegate<MediaSourceEventListener>

    private var _playerId: UUID?
    private var _timeline: Timeline?
    
    init(queue: Queue) {
        self.queue = queue
        mediaSourceDelegates = MulticastDelegate<MediaSourceDelegate>(isThreadSafe: false)
        mediaSourceEventListeners = MulticastDelegate<MediaSourceEventListener>(isThreadSafe: false)
    }

    func prepareSourceInternal(mediaTransferListener: TransferListener?) { fatalError("To override") }
    func releaseSourceInternal() { fatalError("To override") }
    func updateMediaItem() { fatalError("To override") }
    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: CMTime,
        loadCondition: LoadConditionCheckable,
        mediaSourceEventDelegate: MediaSourceEventListener
    ) -> MediaPeriod {
        fatalError("To override")
    }
    func release(mediaPeriod: any MediaPeriod) { fatalError("To override") }
    func continueLoadingRequested(with source: any MediaSource) { fatalError("To override") }

    final func refreshSourceInfo(timeline: Timeline) {
        assert(queue.isCurrent())
        self._timeline = timeline
        mediaSourceDelegates.invokeDelegates { $0.mediaSource(self, sourceInfo: timeline) }
    }

    final func addEventListener(_ listener: MediaSourceEventListener) {
        assert(queue.isCurrent())
        mediaSourceEventListeners.addDelegate(listener)
    }

    final func removeEventListener(_ listener: MediaSourceEventListener) {
        assert(queue.isCurrent())
        mediaSourceEventListeners.removeDelegate(listener)
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
