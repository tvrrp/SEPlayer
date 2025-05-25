//
//  CompositeMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import Foundation

class CompositeMediaSource<ID: AnyObject>: BaseMediaSource {
    private var childSources = NSMapTable<ID, MediaSourceAndListener>.init()
    private var mediaTransferListener: TransferListener?

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) {
        self.mediaTransferListener = mediaTransferListener
    }

    override func enableInternal() {
        for childSource in childSources.dictionaryRepresentation().values {
            if let delegate = childSource.delegate {
                childSource.mediaSource.enable(delegate: delegate)
            }
        }
    }

    override func disableInternal() {
        for childSource in childSources.dictionaryRepresentation().values {
            if let delegate = childSource.delegate {
                childSource.mediaSource.disable(delegate: delegate)
            }
        }
    }

    override func releaseSourceInternal() {
        for childSource in childSources.dictionaryRepresentation().values {
            if let delegate = childSource.delegate {
                childSource.mediaSource.releaseSource(delegate: delegate)
            }
        }
        childSources.removeAllObjects()
    }

    func onChildSourceInfoRefreshed(
        childSourceId: ID,
        mediaSource: MediaSource,
        newTimeline: Timeline
    ) {
        assertionFailure("to override")
    }

    final func prepareChildSource(id: ID, mediaSource: MediaSource) {
        guard childSources.object(forKey: id) == nil else { return }

        let caller = DelegateWrapper<ID>(id: id, onInfoRefreshed: onChildSourceInfoRefreshed)
        childSources.setObject(MediaSourceAndListener(mediaSource: mediaSource, delegate: caller), forKey: id)
        mediaSource.prepareSource(
            delegate: caller,
            mediaTransferListener: mediaTransferListener,
            playerId: playerId!
        )
        if !isEnabled {
            mediaSource.disable(delegate: caller)
        }
    }

    final func enableChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id),
              let delegate = enabledChild.delegate else { return }
        enabledChild.mediaSource.enable(delegate: delegate)
    }

    final func disableChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id),
              let delegate = enabledChild.delegate else { return }
        enabledChild.mediaSource.disable(delegate: delegate)
    }

    final func releaseChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id),
              let delegate = enabledChild.delegate else { return }
        enabledChild.mediaSource.releaseSource(delegate: delegate)
    }

    func getWindowIndexForChildWindowIndex(childSourceId: ID, windowIndex: Int) -> Int { windowIndex }
    func getMediaPeriodIdForChildMediaPeriodId(
        childSourceId: ID,
        mediaPeriodId: MediaPeriodId
    ) -> MediaPeriodId { mediaPeriodId }
    func getMediaTimeForChildMediaTime(
        childSourceId: ID,
        mediaTimeMs: Int64,
        mediaPeriodId: MediaPeriodId?
    ) -> Int64 { mediaTimeMs }
}

private extension CompositeMediaSource {
    final class DelegateWrapper<T: AnyObject>: MediaSourceDelegate {
        let id: T
        let onInfoRefreshed: (T, MediaSource, Timeline) -> Void

        init(id: T, onInfoRefreshed: @escaping (T, MediaSource, Timeline) -> Void) {
            self.id = id
            self.onInfoRefreshed = onInfoRefreshed
        }

        func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline) {
            onInfoRefreshed(id, source, refreshed)
        }
    }

    final class MediaSourceAndListener {
        let mediaSource: MediaSource
        weak var delegate: MediaSourceDelegate?

        init(mediaSource: MediaSource, delegate: MediaSourceDelegate) {
            self.mediaSource = mediaSource
            self.delegate = delegate
        }
    }
}
