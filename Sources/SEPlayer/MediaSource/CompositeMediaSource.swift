//
//  CompositeMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import Foundation.NSMapTable

class CompositeMediaSource<ID: AnyObject>: BaseMediaSource {
    private var childSources = NSMapTable<ID, MediaSourceAndListener>.init()
    private var childSourcesEnumerator: [MediaSourceAndListener] {
        childSources.objectEnumerator()?.compactMap { $0 as? MediaSourceAndListener } ?? []
    }
    private var mediaTransferListener: TransferListener?

    override func prepareSourceInternal(mediaTransferListener: TransferListener?) throws {
        self.mediaTransferListener = mediaTransferListener
    }

    override func enableInternal() {
        for childSource in childSourcesEnumerator {
            childSource.mediaSource.enable(delegate: childSource.delegate)
        }
    }

    override func disableInternal() {
        for childSource in childSourcesEnumerator {
            childSource.mediaSource.disable(delegate: childSource.delegate)
        }
    }

    override func releaseSourceInternal() {
        for childSource in childSourcesEnumerator {
            childSource.mediaSource.releaseSource(delegate: childSource.delegate)
        }
        childSources.removeAllObjects()
    }

    func onChildSourceInfoRefreshed(
        childSourceId: ID,
        mediaSource: MediaSource,
        newTimeline: Timeline
    ) throws {
        assertionFailure("to override")
    }

    final func prepareChildSource(id: ID, mediaSource: MediaSource) throws {
        guard childSources.object(forKey: id) == nil else { return }

        let caller = try DelegateWrapper<ID>(id: id, onInfoRefreshed: onChildSourceInfoRefreshed)
        childSources.setObject(MediaSourceAndListener(mediaSource: mediaSource, delegate: caller), forKey: id)
        try mediaSource.prepareSource(
            delegate: caller,
            mediaTransferListener: mediaTransferListener,
            playerId: playerId!
        )
        if !isEnabled {
            mediaSource.disable(delegate: caller)
        }
    }

    final func enableChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id) else { return }
        enabledChild.mediaSource.enable(delegate: enabledChild.delegate)
    }

    final func disableChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id) else { return }
        enabledChild.mediaSource.disable(delegate: enabledChild.delegate)
    }

    final func releaseChildSource(id: ID) {
        guard let enabledChild = childSources.object(forKey: id) else { return }
        enabledChild.mediaSource.releaseSource(delegate: enabledChild.delegate)
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
        let onInfoRefreshed: (T, MediaSource, Timeline) throws -> Void

        init(id: T, onInfoRefreshed: @escaping (T, MediaSource, Timeline) throws -> Void) rethrows {
            self.id = id
            self.onInfoRefreshed = onInfoRefreshed
        }

        func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline) throws {
            try onInfoRefreshed(id, source, refreshed)
        }
    }

    final class MediaSourceAndListener {
        let mediaSource: MediaSource
        let delegate: MediaSourceDelegate

        init(mediaSource: MediaSource, delegate: MediaSourceDelegate) {
            self.mediaSource = mediaSource
            self.delegate = delegate
        }
    }
}
