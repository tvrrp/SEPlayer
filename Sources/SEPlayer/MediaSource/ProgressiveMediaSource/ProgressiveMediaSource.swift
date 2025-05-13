//
//  ProgressiveMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

final class ProgressiveMediaSource: BaseMediaSource {
    protocol Listener: AnyObject {
        func onSeekMap(source: MediaSource, seekMap: SeekMap)
    }

    weak var listener: Listener?
    var mediaPerionId: MediaPeriodId { fatalError() }
    var mediaItem: MediaItem { assert(queue.isCurrent()); return _mediaItem }

    private let queue: Queue
    private let loaderQueue: Queue
    private var _mediaItem: MediaItem
    private let dataSource: DataSource
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let continueLoadingCheckIntervalBytes: Int

    private var timelineIsPlaceholder: Bool
    private var timelineDuration: Int64
    private var timelineIsSeekable = false
    private var timelineIsLive = false

    private var mediaTransferListener: TransferListener?

    init(
        queue: Queue,
        loaderQueue: Queue,
        mediaItem: MediaItem,
        dataSource: DataSource,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        continueLoadingCheckIntervalBytes: Int
    ) {
        self.queue = queue
        self.loaderQueue = loaderQueue
        self._mediaItem = mediaItem
        self.dataSource = dataSource
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        self.timelineIsPlaceholder = true
        self.timelineDuration = .timeUnset
        super.init(queue: queue)
    }

    override func updateMediaItem() {
//        self.
    }

    override func prepareSourceInternal(mediaTransferListener: (any TransferListener)?) {
        self.mediaTransferListener = mediaTransferListener
        notifySourceInfoRefreshed()
    }

    override func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) -> MediaPeriod {
        if let mediaTransferListener {
            dataSource.addTransferListener(mediaTransferListener)
        }
        return ProgressiveMediaPeriod(
            url: mediaItem.url,
            queue: queue,
            loaderQueue: loaderQueue,
            dataSource: dataSource,
            progressiveMediaExtractor: progressiveMediaExtractor,
            listener: self,
            allocator: allocator,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes
        )
    }

    override func release(mediaPeriod: MediaPeriod) {
        guard let mediaPeriod = mediaPeriod as? ProgressiveMediaPeriod else {
            assertionFailure("Wrong media period type"); return
        }
        mediaPeriod.release()
    }
}

extension ProgressiveMediaSource: ProgressiveMediaPeriod.Listener {
    func sourceInfoRefreshed(duration: Int64, seekMap: SeekMap, isLive: Bool) {
        let duration = duration == .timeUnset ? timelineDuration : duration
        let isSeekable = seekMap.isSeekable()

        guard timelineIsPlaceholder,
              timelineDuration != duration,
              timelineIsSeekable != isSeekable,
              timelineIsLive != isLive else {
            return
        }

        timelineIsPlaceholder = false
        timelineDuration = duration
        timelineIsSeekable = isSeekable
        timelineIsLive = isLive

        notifySourceInfoRefreshed()
        listener?.onSeekMap(source: self, seekMap: seekMap)
    }

    func sourceInfoRefreshed(duration: Int64) {
        let duration = duration == .timeUnset ? timelineDuration : duration
        guard timelineDuration != duration else { return }
        timelineDuration = duration
        notifySourceInfoRefreshed()
    }
}

extension ProgressiveMediaSource {
    func notifySourceInfoRefreshed() {
        let timeline = SinglePeriodTimeline()
        refreshSourceInfo(timeline: timeline)
    }
}
