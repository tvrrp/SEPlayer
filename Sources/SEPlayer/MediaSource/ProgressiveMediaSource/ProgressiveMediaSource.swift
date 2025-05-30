//
//  ProgressiveMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

final class ProgressiveMediaSource: BaseMediaSource, ProgressiveMediaPeriod.Listener {
    protocol Listener: AnyObject {
        func onSeekMap(source: MediaSource, seekMap: SeekMap)
    }

    weak var listener: Listener?

    private let queue: Queue
    private let loaderQueue: Queue
    private var mediaItem: MediaItem
    private let dataSourceFactory: DataSourceFactory
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let continueLoadingCheckIntervalBytes: Int

    private var timelineIsPlaceholder: Bool
    private var timelineDurationUs: Int64
    private var timelineIsSeekable = false
    private var timelineIsLive = false

    private var mediaTransferListener: TransferListener?

    convenience init(
        queue: Queue,
        loaderQueue: Queue,
        mediaItem: MediaItem,
        dataSourceFactory: DataSourceFactory,
        extractorsFactory: ExtractorsFactory,
        continueLoadingCheckIntervalBytes: Int = .continueLoadingCheckIntervalBytes
    ) {
        let progressiveMediaExtractor = BundledMediaExtractor(queue: loaderQueue, extractorsFactory: extractorsFactory)
        self.init(
            queue: queue,
            loaderQueue: loaderQueue,
            mediaItem: mediaItem,
            dataSourceFactory: dataSourceFactory,
            progressiveMediaExtractor: progressiveMediaExtractor,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes
        )
    }

    init(
        queue: Queue,
        loaderQueue: Queue,
        mediaItem: MediaItem,
        dataSourceFactory: DataSourceFactory,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        continueLoadingCheckIntervalBytes: Int = .continueLoadingCheckIntervalBytes
    ) {
        self.queue = queue
        self.loaderQueue = loaderQueue
        self.mediaItem = mediaItem
        self.dataSourceFactory = dataSourceFactory
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        self.timelineIsPlaceholder = true
        self.timelineDurationUs = .timeUnset
        super.init(queue: queue)
    }

    override func getMediaItem() -> MediaItem { mediaItem }

    override func canUpdateMediaItem(new item: MediaItem) -> Bool {
        // TODO:
        return false
    }

    override func updateMediaItem(new item: MediaItem) {
        self.mediaItem = item
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
        let dataSource = dataSourceFactory.createDataSource()
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

    func sourceInfoRefreshed(durationUs: Int64, seekMap: SeekMap, isLive: Bool) {
        let durationUs = durationUs == .timeUnset ? timelineDurationUs : durationUs
        let isSeekable = seekMap.isSeekable()

        if !timelineIsPlaceholder
            && timelineDurationUs == durationUs
            && timelineIsSeekable == isSeekable
            && timelineIsLive == isLive {
            return
        }

        timelineIsPlaceholder = false
        timelineDurationUs = durationUs
        timelineIsSeekable = isSeekable
        timelineIsLive = isLive

        notifySourceInfoRefreshed()
        listener?.onSeekMap(source: self, seekMap: seekMap)
    }

    private func notifySourceInfoRefreshed() {
        var timeline: Timeline = SinglePeriodTimeline(
            mediaItem: mediaItem,
            periodDurationUs: timelineDurationUs,
            windowDurationUs: timelineDurationUs,
            isSeekable: timelineIsSeekable,
            isDynamic: false
        )

        if timelineIsPlaceholder {
            timeline = ForwardingTimelineImpl(timeline: timeline)
        }

        refreshSourceInfo(timeline: timeline)
    }
}

private extension ProgressiveMediaSource {
    final class ForwardingTimelineImpl: ForwardingTimeline {
        override func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
            super.getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: defaultPositionProjectionUs)
            window.isPlaceholder = true
            return window
        }

        override func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
            super.getPeriod(periodIndex: periodIndex, period: &period, setIds: setIds)
            period.isPlaceholder = true
            return period
        }
    }
}

private extension Int {
    static let continueLoadingCheckIntervalBytes: Int = 1024 * 1024
}
