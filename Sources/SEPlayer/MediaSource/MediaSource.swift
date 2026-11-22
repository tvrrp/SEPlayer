//
//  MediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.MediaSource
//    androidx.media3.exoplayer.source.BaseMediaSource
//  Copyright (C) 2016, 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import DataSource
import Foundation
import SEPlayerCommon

public protocol MediaSource: AnyObject {
    var isSingleWindow: Bool { get }

    func getMediaItem() -> MediaItem
    func getInitialTimeline() -> Timeline?
    func canUpdateMediaItem(new item: MediaItem) -> Bool
    func updateMediaItem(new item: MediaItem) throws
    func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws
    func maybeThrowSourceInfoRefreshError() throws
    func enable(delegate: MediaSourceDelegate)
    func createPeriod(
        id: MediaPeriodId,
        bufferedBytesCounter: BufferedBytesCounter,
        startPosition: CMTime
    ) throws -> MediaPeriod
    func release(mediaPeriod: MediaPeriod)
    func disable(delegate: MediaSourceDelegate)
    func releaseSource(delegate: MediaSourceDelegate)
}

public protocol MediaSourceDelegate: AnyObject {
    func mediaSource(_ source: any MediaSource, sourceInfo refreshed: Timeline) throws
}

/// The part ``MediaSource`` implementations share: the delegates of the source, its player, and its timeline.
///
/// Subclasses describe their media in `getMediaItem()`, prepare in `prepareSourceInternal(mediaTransferListener:)`,
/// report timelines with `refreshSourceInfo(timeline:)`, and make and release periods.
open class BaseMediaSource: MediaSource {
    open var isSingleWindow: Bool { true }

    public final var isEnabled: Bool {
        assert(queue.isCurrent())
        return enabledMediaSourceDelegates.count != 0
    }

    public final var playerId: UUID? {
        get { assert(queue.isCurrent()); return _playerId }
        set { assert(queue.isCurrent()); _playerId = newValue }
    }

    private let queue: Queue
    private let mediaSourceDelegates: MulticastDelegate<MediaSourceDelegate>
    private let enabledMediaSourceDelegates: NSHashTable<AnyObject>

    private var didPrepare: Bool = false
    private var _playerId: UUID?
    private var _timeline: Timeline?

    public init(queue: Queue) {
        self.queue = queue
        mediaSourceDelegates = MulticastDelegate<MediaSourceDelegate>(isThreadSafe: false)
        enabledMediaSourceDelegates = NSHashTable()
    }

    open func getMediaItem() -> MediaItem { fatalError("To override") }
    open func getInitialTimeline() -> Timeline? { nil }
    open func canUpdateMediaItem(new item: MediaItem) -> Bool { false }
    open func updateMediaItem(new item: MediaItem) throws {}
    open func prepareSourceInternal(mediaTransferListener: TransferListener?) throws { fatalError("To override") }
    open func releaseSourceInternal() {}
    open func enableInternal() {}
    open func createPeriod(
        id: MediaPeriodId,
        bufferedBytesCounter: BufferedBytesCounter,
        startPosition: CMTime
    ) throws -> MediaPeriod {
        fatalError("To override")
    }

    open func release(mediaPeriod: MediaPeriod) { fatalError("To override") }
    open func disableInternal() {}

    public final func refreshSourceInfo(timeline: Timeline) throws {
        assert(queue.isCurrent())
        self._timeline = timeline
        try mediaSourceDelegates.invokeDelegates { try $0.mediaSource(self, sourceInfo: timeline) }
    }

    public final func prepareSource(delegate: MediaSourceDelegate, mediaTransferListener: TransferListener?, playerId: UUID) throws {
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

    open func maybeThrowSourceInfoRefreshError() throws {}

    public final func enable(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        let wasDisabled = enabledMediaSourceDelegates.count == 0
        enabledMediaSourceDelegates.add(delegate)
        if wasDisabled {
            enableInternal()
        }
    }

    public final func disable(delegate: MediaSourceDelegate) {
        assert(queue.isCurrent())
        let wasEnabled = enabledMediaSourceDelegates.count > 0
        enabledMediaSourceDelegates.remove(delegate)
        if wasEnabled && enabledMediaSourceDelegates.count == 0 {
            disableInternal()
        }
    }

    public final func releaseSource(delegate: MediaSourceDelegate) {
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
