//
//  ProgressiveMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

final class ProgressiveMediaSource: BaseMediaSource {
    var mediaPerionId: MediaPeriodId { fatalError() }
    var mediaItem: MediaItem { assert(queue.isCurrent()); return _mediaItem }

    private let queue: Queue
    private let _mediaItem: MediaItem
    private let dataSource: DataSource
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let continueLoadingCheckIntervalBytes: Int

    private var timelineIsPlaceholder: Bool
    private var timelineDuration: CMTime

    private var mediaTransferListener: TransferListener?

    init(
        queue: Queue,
        mediaItem: MediaItem,
        dataSource: DataSource,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        continueLoadingCheckIntervalBytes: Int
    ) {
        self.queue = queue
        self._mediaItem = mediaItem
        self.dataSource = dataSource
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        self.timelineIsPlaceholder = true
        self.timelineDuration = .indefinite
        super.init(queue: queue)
    }

    override func prepareSourceInternal(mediaTransferListener: (any TransferListener)?) {
        self.mediaTransferListener = mediaTransferListener
        notifySourceInfoRefreshed()
    }

    override func createPeriod(
        id: MediaPeriodId,
//        allocator: Allocator,
        allocator: Allocator2,
        startPosition: CMTime,
        loadCondition: LoadConditionCheckable,
        mediaSourceEventDelegate: MediaSourceEventListener
    ) -> MediaPeriod {
        if let mediaTransferListener {
            dataSource.addTransferListener(mediaTransferListener)
        }
        return ProgressiveMediaPeriod(
            url: mediaItem.url,
            queue: queue,
            dataSource: dataSource,
            progressiveMediaExtractor: progressiveMediaExtractor,
            mediaSourceEventDelegate: mediaSourceEventDelegate,
            delegate: self,
            allocator: allocator,
            loadCondition: loadCondition,
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

extension ProgressiveMediaSource: ProgressiveMediaPeriod.Delegate {
    func sourceInfoRefreshed(duration: CMTime) {
        let duration = duration == .indefinite ? timelineDuration : duration
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
