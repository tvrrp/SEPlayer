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
    private let extractorsFactory: ExtractorsFactory
    private let continueLoadingCheckIntervalBytes: Int

    private var timelineIsPlaceholder: Bool
    private var timelineDurationUs: Int64
    private var timelineIsSeekable = false
    private var timelineIsLive = false

    private var mediaTransferListener: TransferListener?

    init(
        queue: Queue,
        loaderQueue: Queue,
        mediaItem: MediaItem,
        dataSourceFactory: DataSourceFactory,
        extractorsFactory: ExtractorsFactory,
        continueLoadingCheckIntervalBytes: Int = .continueLoadingCheckIntervalBytes
    ) {
        self.queue = queue
        self.loaderQueue = loaderQueue
        self.mediaItem = mediaItem
        self.dataSourceFactory = dataSourceFactory
        self.extractorsFactory = extractorsFactory
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

    override func prepareSourceInternal(mediaTransferListener: (any TransferListener)?) throws {
        self.mediaTransferListener = mediaTransferListener
        try notifySourceInfoRefreshed()
    }

    override func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) throws -> MediaPeriod {
        let dataSource = dataSourceFactory.createDataSource()
        if let mediaTransferListener {
            dataSource.addTransferListener(mediaTransferListener)
        }

        guard let localConfiguration = mediaItem.localConfiguration else {
            throw ErrorBuilder.illegalState
        }

        return ProgressiveMediaPeriod(
            url: localConfiguration.url,
            queue: queue,
            loadQueue: loaderQueue,
            dataSource: dataSource,
            progressiveMediaExtractor: BundledMediaExtractor(
                syncActor: loaderQueue.playerActor(),
                extractorsFactory: extractorsFactory
            ),
            listener: self,
            allocator: allocator,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes
        )
    }

    override func release(mediaPeriod: MediaPeriod) {
        (mediaPeriod as! ProgressiveMediaPeriod).release()
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

        do {
            try notifySourceInfoRefreshed()
        } catch {
            fatalError() // TODO: maybe throw error
        }
        listener?.onSeekMap(source: self, seekMap: seekMap)
    }

    private func notifySourceInfoRefreshed() throws {
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

        try refreshSourceInfo(timeline: timeline)
    }
}

private extension ProgressiveMediaSource {
    final class ForwardingTimelineImpl: ForwardingTimeline, @unchecked Sendable {
        override func getWindow(windowIndex: Int, window: Window, defaultPositionProjectionUs: Int64) -> Window {
            super.getWindow(windowIndex: windowIndex, window: window, defaultPositionProjectionUs: defaultPositionProjectionUs)
            window.isPlaceholder = true
            return window
        }

        override func getPeriod(periodIndex: Int, period: Period, setIds: Bool) -> Period {
            super.getPeriod(periodIndex: periodIndex, period: period, setIds: setIds)
            period.isPlaceholder = true
            return period
        }
    }
}

private extension Int {
    static let continueLoadingCheckIntervalBytes: Int = 1024 * 1024
}
