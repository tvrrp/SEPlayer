//
//  SEPlayerImpl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import AVFoundation

final class SEPlayerImpl: BasePlayer, SEPlayer {
    @MainActor public let delegate = MulticastDelegate<SEPlayerDelegate>(isThreadSafe: false)

    let clock: SEClock
    var playbackState: PlayerState { queue.sync { playbackInfo.state } }

    var isPlaying: Bool { queue.sync { playbackInfo.isPlaying } }

    var playWhenReady: Bool {
        get { queue.sync { playbackInfo.playWhenReady } }
        set { setPlayWhenReady(newValue) }
    }

    var repeatMode: RepeatMode {
        get { queue.sync { _repeatMode } }
        set { setRepeatMode(newValue) }
    }

    var shuffleModeEnabled: Bool {
        get { queue.sync { _shuffleModeEnabled } }
        set { setShuffleModeEnabled(newValue) }
    }

    var seekParameters: SeekParameters {
        get { queue.sync { _seekParameters } }
        set { setSeekParameters(newValue) }
    }

    var volume: Float {
        get { queue.sync { internalPlayer.volume } }
        set { queue.async { self.internalPlayer.volume = newValue } }
    }

    var isMuted: Bool {
        get { queue.sync { internalPlayer.isMuted } }
        set { queue.async { self.internalPlayer.isMuted = newValue } }
    }

    var isLoading: Bool { queue.sync { playbackInfo.isLoading } }

    let seekBackIncrement: Int64
    let seekForwardIncrement: Int64
    let maxSeekToPreviousPosition: Int64

    var playbackParameters: PlaybackParameters {
        get { queue.sync { playbackInfo.playbackParameters } }
        set { setPlaybackParameters(newValue) }
    }

    var timeline: Timeline { queue.sync { playbackInfo.timeline } }

    var currentPeriodIndex: Int? {
        queue.sync {
            if playbackInfo.timeline.isEmpty {
                maskingPeriodIndex
            } else {
                playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId)
            }
        }
    }

    var preloadConfiguration: PreloadConfiguration {
        get { queue.sync { _preloadConfiguration } }
        set { setPreloadConfiguration(newValue) }
    }

    var currentMediaItemIndex: Int {
        queue.sync { currentWindowIndexInternal(playbackInfo: playbackInfo) ?? .zero }
    }

    var duration: Int64 { queue.sync { contentDuration } }

    var currentPosition: Int64 {
        queue.sync {
            Time.usToMs(timeUs: currentPositionUsInternal(playbackInfo: playbackInfo))
        }
    }

    var bufferedPosition: Int64 { queue.sync { contentBufferedPosition } }

    var totalBufferedDuration: Int64 { queue.sync { Time.usToMs(timeUs: playbackInfo.totalBufferedDurationUs) } }

    var contentPosition: Int64 { queue.sync { contentPositionInternal(playbackInfo: playbackInfo) } }

    var contentBufferedPosition: Int64 { queue.sync { getContentBufferedPosition() } }

    var pauseAtTheEndOfMediaItem: Bool {
        get { queue.sync { _pauseAtTheEndOfMediaItem } }
        set { setPauseAtEndOfMediaItems(newValue) }
    }

    var window: Window

    private let queue: Queue
    private let workQueue: Queue
    private let mediaSourceFactory: MediaSourceFactory
    private let emptyTrackSelectorResult: TrackSelectionResult
    private let renderers: [SERenderer]
    private let internalPlayer: SEPlayerImplInternal
    private let useLazyPreparation: Bool

    private var period: Period
    private var mediaSourceHolderSnapshots: [MediaSourceHolderSnapshot] = []
    private var playbackInfo: PlaybackInfo
    private var _repeatMode: RepeatMode
    private var _shuffleModeEnabled: Bool
    private var _seekParameters: SeekParameters
    private var _shufflerOrder: ShuffleOrder
    private var _preloadConfiguration: PreloadConfiguration
    private var _pauseAtTheEndOfMediaItem: Bool

    private var maskingWindowIndex: Int?
    private var maskingPeriodIndex: Int = 0
    private var maskingWindowPositionMs: Int64 = 0
    private var pendingOperationAcks: Int = 0
    private var pendingDiscontinuityReason: DiscontinuityReason = .autoTransition
    private var pendingDiscontinuity: Bool = false

    init(
        identifier: UUID,
        workQueue: Queue,
        applicationQueue: Queue,
        clock: SEClock,
        renderersFactory: RenderersFactory,
        trackSelector: TrackSelector,
        loadControl: LoadControl,
        bandwidthMeter: BandwidthMeter,
        mediaSourceFactory: MediaSourceFactory,
        audioSessionManager: IAudioSessionManager,
        useLazyPreparation: Bool = true,
        seekParameters: SeekParameters = .default,
        seekBackIncrementMs: Int64 = 5_000,
        seekForwardIncrementMs: Int64 = 5_000,
        maxSeekToPreviousPositionMs: Int64 = 3000,
        pauseAtTheEndOfMediaItem: Bool = false
    ) {
        self.workQueue = workQueue
        self.queue = applicationQueue
        self.clock = clock
        self.mediaSourceFactory = mediaSourceFactory
        self.useLazyPreparation = useLazyPreparation
        _seekParameters = seekParameters
        seekBackIncrement = seekBackIncrementMs
        seekForwardIncrement = seekForwardIncrementMs
        maxSeekToPreviousPosition = maxSeekToPreviousPositionMs
        _pauseAtTheEndOfMediaItem = pauseAtTheEndOfMediaItem

        let renderSynchronizer = AVSampleBufferRenderSynchronizer()
        self.renderers = renderersFactory.createRenderers(
            queue: workQueue,
            clock: clock,
            renderSynchronizer: renderSynchronizer
        )
        emptyTrackSelectorResult = TrackSelectionResult(
            renderersConfig: Array(repeating: nil, count: renderers.count),
            selections: Array(repeating: nil, count: renderers.count),
            tracks: Tracks(groups: [])
        )

        playbackInfo = PlaybackInfo.dummy(clock: clock, emptyTrackSelectorResult: emptyTrackSelectorResult)
        _repeatMode = .off
        _shuffleModeEnabled = false
        _shufflerOrder = DefaultShuffleOrder(length: 0)
        _preloadConfiguration = .default

        window = Window()
        period = Period()

        internalPlayer = try! SEPlayerImplInternal(
            queue: workQueue,
            renderers: renderers,
            trackSelector: trackSelector,
            emptyTrackSelectorResult: emptyTrackSelectorResult,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            repeatMode: _repeatMode,
            shuffleModeEnabled: _shuffleModeEnabled,
            seekParameters: seekParameters,
            pauseAtEndOfWindow: pauseAtTheEndOfMediaItem,
            clock: clock,
            mediaClock: DefaultMediaClock(clock: clock),
            identifier: identifier,
            preloadConfiguration: _preloadConfiguration,
            audioSessionManager: audioSessionManager
        )

        internalPlayer.playbackInfoUpdateListener = self
    }

    func prepare() {
        queue.async { [weak self] in
            guard let self, playbackInfo.state == .idle else { return }
            let playbackInfo = mask(
                playbackState: playbackInfo.timeline.isEmpty ? .ended : .buffering, playbackInfo: playbackInfo.setPlaybackError(nil)
            )
            pendingOperationAcks += 1
            self.internalPlayer.prepare()
            updatePlaybackInfo(
                new: playbackInfo,
                timelineChangeReason: .sourceUpdate,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPositionUs: .timeUnset,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func set(mediaItems: [MediaItem], resetPosition: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            set(
                mediaSources: createMediaSources(mediaItems: mediaItems),
                resetPosition: resetPosition
            )
        }
    }

    func set(mediaItems: [MediaItem], startIndex: Int, startPositionMs: Int64) {
        queue.async { [weak self] in
            guard let self else { return }

            set(
                mediaSources: createMediaSources(mediaItems: mediaItems),
                startMediaItemIndex: startIndex,
                startPositionMs: startPositionMs
            )
        }
    }

    func set(mediaSource: MediaSource) {
        set(mediaSources: [mediaSource])
    }

    func set(mediaSource: MediaSource, startPositionMs: Int64) {
        set(
            mediaSources: [mediaSource],
            startMediaItemIndex: 0,
            startPositionMs: startPositionMs
        )
    }

    func set(mediaSource: MediaSource, resetPosition: Bool) {
        set(mediaSources: [mediaSource], resetPosition: resetPosition)
    }

    func set(mediaSources: [MediaSource]) {
        set(mediaSources: mediaSources, resetPosition: true)
    }

    func set(mediaSources: [MediaSource], resetPosition: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            setMediaSourcesInternal(
                mediaSources,
                startWindowIndex: nil,
                startPositionMs: .timeUnset,
                resetToDefaultPosition: resetPosition
            )
        }
    }

    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPositionMs: Int64) {
        queue.async { [weak self] in
            guard let self else { return }

            setMediaSourcesInternal(
                mediaSources,
                startWindowIndex: startMediaItemIndex,
                startPositionMs: startPositionMs,
                resetToDefaultPosition: false
            )
        }
    }

    func insert(mediaItems: [MediaItem], at position: Int) {
        queue.async { [weak self] in
            guard let self else { return }

            insert(mediaSources: createMediaSources(mediaItems: mediaItems), at: position)
        }
    }

    func append(mediaSource: MediaSource) {
        append(mediaSources: [mediaSource])
    }

    func insert(mediaSource: MediaSource, at index: Int) {
        insert(mediaSources: [mediaSource], at: index)
    }

    func append(mediaSources: [MediaSource]) {
        queue.async { [weak self] in
            guard let self else { return }

            insert(
                mediaSources: mediaSources,
                at: mediaSourceHolderSnapshots.count
            )
        }
    }

    func insert(mediaSources: [MediaSource], at index: Int) {
        queue.async { [weak self] in
            guard let self, index >= 0 else { return }

            let index = min(index, mediaSourceHolderSnapshots.count)
            if mediaSourceHolderSnapshots.isEmpty {
                set(mediaSources: mediaSources, resetPosition: maskingWindowIndex == nil)
                return
            }

            let newPlaybackInfo = addMediaSourcesInternal(mediaSources, playbackInfo: playbackInfo, at: index)
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPositionUs: .timeUnset,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func removeMediaItems(at range: Range<Int>) {
        queue.async { [weak self] in
            guard let self else { return }

            let playlistSize = mediaSourceHolderSnapshots.count
            let clampedRange = range.lowerBound..<min(range.upperBound, playlistSize)
            guard !clampedRange.isEmpty else { return }

            let newPlaybackInfo = removeMediaItemsInternal(
                playbackInfo: playbackInfo,
                range: clampedRange
            )

            let positionDiscontinuity = newPlaybackInfo.periodId.periodId != playbackInfo.periodId.periodId
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: positionDiscontinuity,
                positionDiscontinuityReason: .remove,
                discontinuityWindowStartPositionUs: currentPositionUsInternal(playbackInfo: newPlaybackInfo),
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func moveMediaItems(range: Range<Int>, to newIndex: Int) {
        queue.async { [weak self] in
            guard let self else { return }

            let playlistSize = mediaSourceHolderSnapshots.count
            let fromIndex = range.lowerBound
            let toIndex = min(range.upperBound, playlistSize)
            let clampedRange = fromIndex..<toIndex
            let itemCount = clampedRange.count
            let adjustedNewIndex = min(newIndex, playlistSize - itemCount)

            guard fromIndex < playlistSize || fromIndex != toIndex || fromIndex != adjustedNewIndex else {
                return
            }

            let oldTimeline = timeline
            pendingOperationAcks += 1
            let finalInsertIndex = adjustedNewIndex > fromIndex ? adjustedNewIndex - itemCount : adjustedNewIndex
            if #available(iOS 18.0, *) {
                mediaSourceHolderSnapshots.moveSubranges(.init(clampedRange), to: finalInsertIndex)
            } else {
                let itemsToMove = Array(mediaSourceHolderSnapshots[clampedRange])
                mediaSourceHolderSnapshots.removeSubrange(clampedRange)

                mediaSourceHolderSnapshots.insert(contentsOf: itemsToMove, at: finalInsertIndex)
            }

            _shufflerOrder = _shufflerOrder
                .cloneAndRemove(indexFrom: clampedRange.lowerBound, indexToExclusive: clampedRange.upperBound)
                .cloneAndInsert(insertionIndex: finalInsertIndex, insertionCount: clampedRange.count)

            let newTimeline = createMaskingTimeline()
            let newPlaybackInfo = maskTimelineAndPosition(
                playbackInfo: playbackInfo,
                timeline: newTimeline,
                periodPositionUs: periodPositionUsAfterTimelineChanged(
                    oldTimeline: oldTimeline,
                    newTimeline: newTimeline,
                    currentWindowIndexInternal: currentWindowIndexInternal(playbackInfo: playbackInfo),
                    contentPositionMs: contentPositionInternal(playbackInfo: playbackInfo)
                )
            )
            internalPlayer.moveMediaSources(
                range: range, to: newIndex, shuffleOrder: self._shufflerOrder
            )
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPositionUs: .timeUnset,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func replace(mediaItems: [MediaItem], at range: Range<Int>) {
        queue.async { [weak self] in
            guard let self, range.upperBound < mediaSourceHolderSnapshots.count else { return }

            let clampedRange = range.lowerBound..<min(range.upperBound, mediaSourceHolderSnapshots.count)

            if canUpdateMediaSources(with: mediaItems, range: clampedRange) {
                updateMediaSources(with: mediaItems, range: clampedRange)
                return
            }

            let mediaSources = createMediaSources(mediaItems: mediaItems)
            if mediaSourceHolderSnapshots.isEmpty {
                set(mediaSources: mediaSources, resetPosition: maskingWindowIndex == nil)
            }

            var newPlaybackInfo = addMediaSourcesInternal(mediaSources, playbackInfo: playbackInfo, at: clampedRange.upperBound)
            newPlaybackInfo = removeMediaItemsInternal(playbackInfo: playbackInfo, range: clampedRange)
            let positionDiscontinuity = newPlaybackInfo.periodId.periodId != newPlaybackInfo.periodId.periodId
            updatePlaybackInfo(
                new: playbackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: positionDiscontinuity,
                positionDiscontinuityReason: .remove,
                discontinuityWindowStartPositionUs: currentPositionUsInternal(playbackInfo: newPlaybackInfo),
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func set(shuffleOrder: ShuffleOrder) {
        queue.async { [weak self] in
            guard let self, shuffleOrder.count == mediaSourceHolderSnapshots.count else { return }
            self._shufflerOrder = shuffleOrder
            let timeline = createMaskingTimeline()
            let newPlaybackInfo = maskTimelineAndPosition(
                playbackInfo: playbackInfo,
                timeline: timeline,
                periodPositionUs: maskWindowPositionMsOrGetPeriodPositionUs(
                    timeline: timeline,
                    windowIndex: currentMediaItemIndex,
                    windowPositionMs: currentPosition
                )
            )
            pendingOperationAcks += 1
            internalPlayer.setShuffleOrder(shuffleOrder)
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPositionUs: .timeUnset,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    func setPauseAtEndOfMediaItems(_ pauseAtEndOfMediaItems: Bool) {
        queue.async { [weak self] in
            guard let self, _pauseAtTheEndOfMediaItem != pauseAtEndOfMediaItems else { return }
            _pauseAtTheEndOfMediaItem = pauseAtEndOfMediaItems
            internalPlayer.setPauseAtEndOfWindow(pauseAtEndOfMediaItems)
        }
    }

    private func setPlayWhenReady(_ playWhenReady: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            updatePlayWhenReady(playWhenReady, changeReason: .userRequest)
        }
    }

    private func setRepeatMode(_ repeatMode: RepeatMode) {
        queue.async { [weak self] in
            guard let self, _repeatMode != repeatMode else { return }
            _repeatMode = repeatMode
            internalPlayer.setRepeatMode(repeatMode)
        }
    }

    private func setShuffleModeEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, _shuffleModeEnabled != enabled else { return }
            _shuffleModeEnabled = enabled
            internalPlayer.setShuffleModeEnabled(enabled)
        }
    }

    private func setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration) {
        queue.async { [weak self] in
            guard let self, _preloadConfiguration != preloadConfiguration else { return }
            _preloadConfiguration = preloadConfiguration
            internalPlayer.setPreloadConfiguration(preloadConfiguration)
        }
    }

    func seek(to mediaItemIndex: Int?, positionMs: Int64, isRepeatingCurrentItem: Bool) {
        queue.async { [weak self] in
            guard let self, let mediaItemIndex, mediaItemIndex >= 0 else { return }

            let timeline = playbackInfo.timeline
            if !timeline.isEmpty && mediaItemIndex >= timeline.windowCount() {
                return
            }

            // TODO: ad

            pendingOperationAcks += 1
            var newPlaybackInfo = if playbackInfo.state == .ready || (playbackInfo.state == .ended && !timeline.isEmpty) {
                mask(playbackState: .buffering, playbackInfo: playbackInfo)
            } else {
                playbackInfo
            }

            let oldMaskingMediaItemIndex = currentMediaItemIndex
            newPlaybackInfo = maskTimelineAndPosition(
                playbackInfo: newPlaybackInfo,
                timeline: timeline,
                periodPositionUs: maskWindowPositionMsOrGetPeriodPositionUs(
                    timeline: timeline,
                    windowIndex: mediaItemIndex,
                    windowPositionMs: positionMs
                )
            )
            self.internalPlayer.seekTo(
                timeline: timeline,
                windowIndex: mediaItemIndex,
                positionUs: Time.msToUs(timeMs: positionMs)
            )
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: true,
                positionDiscontinuityReason: .seek,
                discontinuityWindowStartPositionUs: currentPositionUsInternal(playbackInfo: playbackInfo),
                oldMaskingMediaItemIndex: oldMaskingMediaItemIndex,
                repeatCurrentMediaItem: isRepeatingCurrentItem
            )
        }
    }

    private func setPlaybackParameters(_ playbackParameters: PlaybackParameters) {
        queue.async { [weak self] in
            guard let self, playbackInfo.playbackParameters != playbackParameters else { return }

            let newPlaybackInfo = playbackInfo.playbackParameters(playbackParameters)
            pendingOperationAcks += 1
            internalPlayer.setPlaybackParameters(playbackParameters)
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPositionUs: .timeUnset,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }

    private func setSeekParameters(_ seekParameters: SeekParameters) {
        queue.async { [weak self] in
            guard let self, _seekParameters != seekParameters else { return }
            _seekParameters = seekParameters
            internalPlayer.setSeekParameters(seekParameters)
        }
    }

    func stop() {
        queue.async {
            self.stopInternal(error: nil)
        }
    }

    func releaseAsync() async {
        await internalPlayer.release()
        playbackInfo = mask(playbackState: .idle, playbackInfo: playbackInfo)
        playbackInfo = playbackInfo.loadingMediaPeriodId(playbackInfo.periodId)
    }

    public func createMessage(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage {
        queue.sync { createMessageInternal(handler: handler) }
    }

    private func getContentBufferedPosition() -> Int64 {
        assert(queue.isCurrent())
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowPositionMs
        }

        if playbackInfo.loadingMediaPeriodId.windowSequenceNumber != playbackInfo.periodId.windowSequenceNumber {
            let timeUs = playbackInfo.timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).durationUs
            return Time.usToMs(timeUs: timeUs)
        }

        return Time.usToMs(timeUs: periodPositionUs(
            to: playbackInfo.bufferedPositionUs,
            timeline: playbackInfo.timeline,
            periodId: playbackInfo.loadingMediaPeriodId
        ))
    }

    private func stopInternal(error: Error?) {
        assert(queue.isCurrent())
        var playbackInfo = playbackInfo.loadingMediaPeriodId(playbackInfo.periodId)
        playbackInfo.bufferedPositionUs = playbackInfo.positionUs
        playbackInfo.totalBufferedDurationUs = 0
        playbackInfo = mask(playbackState: .idle, playbackInfo: playbackInfo)
        if let error {
            playbackInfo = playbackInfo.setPlaybackError(error)
        }
        pendingOperationAcks += 1
        internalPlayer.stop()
        updatePlaybackInfo(
            new: playbackInfo,
            timelineChangeReason: .playlistChanged,
            positionDiscontinuity: false,
            positionDiscontinuityReason: .internal,
            discontinuityWindowStartPositionUs: .timeUnset,
            oldMaskingMediaItemIndex: nil,
            repeatCurrentMediaItem: false
        )
    }

    private func currentWindowIndexInternal(playbackInfo: PlaybackInfo) -> Int? {
        assert(queue.isCurrent())
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowIndex
        }

        return playbackInfo.timeline
            .periodById(playbackInfo.periodId.periodId, period: period).windowIndex
    }

    func contentPositionInternal(playbackInfo: PlaybackInfo) -> Int64 {
        assert(queue.isCurrent())
        return Time.usToMs(timeUs: currentPositionUsInternal(playbackInfo: playbackInfo))
    }

    func currentPositionUsInternal(playbackInfo: PlaybackInfo) -> Int64 {
        assert(queue.isCurrent())
        guard !playbackInfo.timeline.isEmpty else {
            return Time.msToUs(timeMs: maskingWindowPositionMs)
        }

        return periodPositionUs(
            to: playbackInfo.positionUs,
            timeline: playbackInfo.timeline,
            periodId: playbackInfo.periodId
        )
    }

    private func createMediaSources(mediaItems: [MediaItem]) -> [MediaSource] {
        mediaItems.map { mediaSourceFactory.createMediaSource(mediaItem: $0) }
    }

    private func updatePlaybackInfo(
        new playbackInfo: PlaybackInfo,
        timelineChangeReason: TimelineChangeReason,
        positionDiscontinuity: Bool,
        positionDiscontinuityReason: DiscontinuityReason,
        discontinuityWindowStartPositionUs: Int64,
        oldMaskingMediaItemIndex: Int?,
        repeatCurrentMediaItem: Bool
    ) {
        assert(queue.isCurrent())
        let previousPlaybackInfo = self.playbackInfo
        let newPlaybackInfo = playbackInfo
        self.playbackInfo = playbackInfo

        let timelineChanged = !previousPlaybackInfo.timeline.equals(to: newPlaybackInfo.timeline)
        let (mediaItemTransitioned, mediaItemTransitionReason) = evaluateMediaItemTransitionReason(
            playbackInfo: newPlaybackInfo,
            oldPlaybackInfo: previousPlaybackInfo,
            positionDiscontinuity: positionDiscontinuity,
            positionDiscontinuityReason: positionDiscontinuityReason,
            timelineChanged: timelineChanged,
            repeatCurrentMediaItem: repeatCurrentMediaItem
        )

        var mediaItem: MediaItem?

        if mediaItemTransitioned {
            if !newPlaybackInfo.timeline.isEmpty {
                let windowIndex = newPlaybackInfo.timeline.periodById(
                    newPlaybackInfo.periodId.periodId,
                    period: period
                ).windowIndex
                mediaItem = newPlaybackInfo.timeline.getWindow(windowIndex: windowIndex, window: window).mediaItem
            }
        }

        let playWhenReadyChanged = previousPlaybackInfo.playWhenReady != newPlaybackInfo.playWhenReady
        let playbackStateChanged = previousPlaybackInfo.state != newPlaybackInfo.state
        let isLoadingChanged = previousPlaybackInfo.isLoading != newPlaybackInfo.isLoading

        if timelineChanged {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeTimeline: newPlaybackInfo.timeline, reason: timelineChangeReason) }
            }
        }

        if positionDiscontinuity {
            let previousPositionInfo = previousPositionInfo(
                positionDiscontinuityReason: positionDiscontinuityReason,
                oldPlaybackInfo: previousPlaybackInfo,
                oldMaskingMediaItemIndex: oldMaskingMediaItemIndex
            )
            let positionInfo = positionInfo(for: discontinuityWindowStartPositionUs)
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(
                        self,
                        didChangePositionDiscontinuity: previousPositionInfo,
                        newPosition: positionInfo,
                        reason: positionDiscontinuityReason
                    )
                }
            }
        }

        if mediaItemTransitioned {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didTransitionMediaItem: mediaItem, reason: mediaItemTransitionReason)
                }
            }
        }

        if (previousPlaybackInfo.playbackError == nil && newPlaybackInfo.playbackError != nil) ||
            (previousPlaybackInfo.playbackError != nil && newPlaybackInfo.playbackError == nil) {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didChangePlayerError: newPlaybackInfo.playbackError)
                }

                if let newError = newPlaybackInfo.playbackError {
                    delegate.invokeDelegates {
                        $0.player(self, onPlayerError: newError)
                    }
                }
            }
        }

        if previousPlaybackInfo.trackSelectorResult != newPlaybackInfo.trackSelectorResult {
            // TODO:
        }

        if isLoadingChanged {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeIsLoading: newPlaybackInfo.isLoading) }
            }
        }

        if playbackStateChanged {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangePlaybackState: newPlaybackInfo.state) }
            }
        }

        if playWhenReadyChanged || previousPlaybackInfo.playWhenReadyChangeReason != newPlaybackInfo.playWhenReadyChangeReason {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didChangePlayWhenReady: newPlaybackInfo.playWhenReady, reason: newPlaybackInfo.playWhenReadyChangeReason)
                }
            }
        }

        if previousPlaybackInfo.playbackSuppressionReason != newPlaybackInfo.playbackSuppressionReason {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didChangePlaybackSuppressionReason: newPlaybackInfo.playbackSuppressionReason)
                }
            }
        }

        if previousPlaybackInfo.isPlaying != newPlaybackInfo.isPlaying {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeIsPlaying: newPlaybackInfo.isPlaying) }
            }
        }

        if previousPlaybackInfo.playbackParameters != newPlaybackInfo.playbackParameters {
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangePlaybackParameters: newPlaybackInfo.playbackParameters) }
            }
        }
    }

    private func previousPositionInfo(
        positionDiscontinuityReason: DiscontinuityReason,
        oldPlaybackInfo: PlaybackInfo,
        oldMaskingMediaItemIndex: Int?
    ) -> PositionInfo {
        assert(queue.isCurrent())
        var oldWindowId: AnyHashable?
        var oldPeriodId: AnyHashable?
        var oldMediaItemIndex = oldMaskingMediaItemIndex
        var oldPeriodIndex: Int?
        var oldMediaItem: MediaItem?
        let oldPeriod = Period()

        if !oldPlaybackInfo.timeline.isEmpty {
            oldPeriodId = oldPlaybackInfo.periodId.periodId
            oldPlaybackInfo.timeline.periodById(oldPlaybackInfo.periodId.periodId, period: oldPeriod)
            oldMediaItemIndex = oldPeriod.windowIndex
            oldPeriodIndex = oldPlaybackInfo.timeline.indexOfPeriod(by: oldPlaybackInfo.periodId.periodId)
            oldWindowId = oldPlaybackInfo.timeline.getWindow(windowIndex: oldPeriod.windowIndex, window: window).id
            oldMediaItem = window.mediaItem
        }

        let oldPositionUs: Int64
        let oldContentPositionUs: Int64

        if positionDiscontinuityReason == .autoTransition {
            oldPositionUs = oldPeriod.positionInWindowUs + oldPeriod.durationUs
            oldContentPositionUs = oldPositionUs
        } else {
            oldPositionUs = oldPeriod.positionInWindowUs + oldPlaybackInfo.positionUs
            oldContentPositionUs = oldPositionUs
        }

        return PositionInfo(
            windowId: oldWindowId,
            mediaItemIndex: oldMediaItemIndex,
            mediaItem: oldMediaItem,
            periodId: oldPeriodId,
            periodIndex: oldPeriodIndex,
            positionMs: Time.usToMs(timeUs: oldPositionUs),
            contentPositionMs: Time.usToMs(timeUs: oldContentPositionUs)
        )
    }

    private func positionInfo(for discontinuityWindowStartPositionUs: Int64) -> PositionInfo {
        assert(queue.isCurrent())
        var newWindowId: AnyHashable?
        var newPeriodId: AnyHashable?
        let newMediaItemIndex = currentMediaItemIndex
        var newPeriodIndex: Int?
        var newMediaItem: MediaItem?

        if !playbackInfo.timeline.isEmpty {
            newPeriodId = playbackInfo.periodId.periodId
            playbackInfo.timeline.periodById(playbackInfo.periodId.periodId, period: period)
            newPeriodIndex = playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId)
            newWindowId = playbackInfo.timeline.getWindow(windowIndex: newMediaItemIndex, window: window).id
            newMediaItem = window.mediaItem
        }

        let positionMs = Time.usToMs(timeUs: discontinuityWindowStartPositionUs)
        return PositionInfo(
            windowId: newWindowId,
            mediaItemIndex: newMediaItemIndex,
            mediaItem: newMediaItem,
            periodId: newPeriodId,
            periodIndex: newPeriodIndex,
            positionMs: positionMs,
            contentPositionMs: positionMs
        )
    }

    private func requestedContentPositionUs(playbackInfo: PlaybackInfo) -> Int64 {
        assert(queue.isCurrent())
        let window = Window()
        let period = Period()
        playbackInfo.timeline.periodById(playbackInfo.periodId.periodId, period: period)

        if playbackInfo.requestedContentPositionUs == .timeUnset {
            return playbackInfo.timeline.getWindow(windowIndex: period.windowIndex, window: window).defaultPositionUs
        } else {
            return period.positionInWindowUs + playbackInfo.requestedContentPositionUs
        }
    }

    private func evaluateMediaItemTransitionReason(
        playbackInfo: PlaybackInfo,
        oldPlaybackInfo: PlaybackInfo,
        positionDiscontinuity: Bool,
        positionDiscontinuityReason: DiscontinuityReason,
        timelineChanged: Bool,
        repeatCurrentMediaItem: Bool
    ) -> (didTransition: Bool, reason: MediaItemTransitionReason?) {
        assert(queue.isCurrent())
        let oldTimeline = oldPlaybackInfo.timeline
        let newTimeline = playbackInfo.timeline

        if oldTimeline.isEmpty, newTimeline.isEmpty {
            return(false, nil)
        } else if oldTimeline.isEmpty != newTimeline.isEmpty {
            return (true, .playlistChanged)
        }

        let oldWindowIndex = oldTimeline.periodById(oldPlaybackInfo.periodId.periodId, period: period).windowIndex
        let oldWindowId = oldTimeline.getWindow(windowIndex: oldWindowIndex, window: window).id
        let newWindowIndex = newTimeline.periodById(playbackInfo.periodId.periodId, period: period).windowIndex
        let newWindowId = newTimeline.getWindow(windowIndex: newWindowIndex, window: window).id

        if oldWindowId != newWindowId {
            let transitionReason: MediaItemTransitionReason? = if positionDiscontinuity, positionDiscontinuityReason == .autoTransition {
                .auto
            } else if positionDiscontinuity, positionDiscontinuityReason == .seek {
                .seek
            } else if timelineChanged {
                .playlistChanged
            } else {
                nil // TODO: throw error
            }

            return (true, transitionReason)
        } else {
            if positionDiscontinuity, positionDiscontinuityReason == .autoTransition,
               let oldWindowSequenceNumber = oldPlaybackInfo.periodId.windowSequenceNumber,
               let newWindowSequenceNumber = playbackInfo.periodId.windowSequenceNumber,
               oldWindowSequenceNumber < newWindowSequenceNumber {
                return (true, .repeat)
            }

            if positionDiscontinuity, repeatCurrentMediaItem,
                positionDiscontinuityReason == .seek {
                return (true, .seek)
            }
        }

        return (false, nil)
    }

    private func setMediaSourcesInternal(
        _ mediaSources: [MediaSource],
        startWindowIndex: Int?,
        startPositionMs: Int64,
        resetToDefaultPosition: Bool
    ) {
        assert(queue.isCurrent())
        var startWindowIndex = startWindowIndex
        var startPositionMs = startPositionMs
        let currentWindowIndex = currentWindowIndexInternal(playbackInfo: playbackInfo)
        let currentPositionMs = currentPosition
        pendingOperationAcks += 1
        if !mediaSourceHolderSnapshots.isEmpty {
            removeMediaSourceHolders(range: 0..<mediaSourceHolderSnapshots.count)
        }

        let holders = addMediaSourceHolders(mediaSources, at: 0)
        let timeline = createMaskingTimeline()

        if !timeline.isEmpty, startWindowIndex ?? .zero >= timeline.windowCount() {
            // TODO: throw error
            return
        }

        if resetToDefaultPosition {
            startWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            startPositionMs = .timeUnset
        } else if startWindowIndex == nil {
            startWindowIndex = currentWindowIndex
            startPositionMs = currentPositionMs
        }

        var newPlaybackInfo = maskTimelineAndPosition(
            playbackInfo: playbackInfo,
            timeline: timeline,
            periodPositionUs: maskWindowPositionMsOrGetPeriodPositionUs(
                timeline: timeline,
                windowIndex: startWindowIndex,
                windowPositionMs: startPositionMs
            )
        )

        var maskingPlaybackState = newPlaybackInfo.state
        if let startWindowIndex, newPlaybackInfo.state != .idle {
            if timeline.isEmpty || startWindowIndex >= timeline.windowCount() {
                maskingPlaybackState = .ended
            } else {
                maskingPlaybackState = .buffering
            }
        }

        newPlaybackInfo = mask(playbackState: maskingPlaybackState, playbackInfo: newPlaybackInfo)
        internalPlayer.setMediaSources(
            holders,
            windowIndex: startWindowIndex,
            positionUs: Time.msToUs(timeMs: startPositionMs),
            shuffleOrder: _shufflerOrder
        )

        let positionDiscontinuity = playbackInfo.periodId.periodId != newPlaybackInfo.periodId.periodId && !playbackInfo.timeline.isEmpty
        updatePlaybackInfo(
            new: newPlaybackInfo,
            timelineChangeReason: .playlistChanged,
            positionDiscontinuity: positionDiscontinuity,
            positionDiscontinuityReason: .remove,
            discontinuityWindowStartPositionUs: currentPositionUsInternal(playbackInfo: newPlaybackInfo),
            oldMaskingMediaItemIndex: nil,
            repeatCurrentMediaItem: false
        )
    }

    private func addMediaSourceHolders(_ mediaSources: [MediaSource], at index: Int) -> [MediaSourceList.MediaSourceHolder] {
        assert(queue.isCurrent())
        var holders = [MediaSourceList.MediaSourceHolder]()
        for (i, mediaSource) in mediaSources.enumerated() {
            let holder = MediaSourceList.MediaSourceHolder(
                queue: workQueue,
                mediaSource: mediaSource,
                useLazyPreparation: useLazyPreparation
            )
            holders.append(holder)

            let holderSnapshot = MediaSourceHolderSnapshot(id: holder.id, mediaSource: holder.mediaSource)
            mediaSourceHolderSnapshots.insert(holderSnapshot, at: i + index)
        }
        _shufflerOrder = _shufflerOrder.cloneAndInsert(
            insertionIndex: index,
            insertionCount: holders.count
        )

        return holders
    }

    @discardableResult
    private func addMediaSourcesInternal(
        _ mediaSources: [MediaSource],
        playbackInfo: PlaybackInfo,
        at index: Int
    ) -> PlaybackInfo {
        assert(queue.isCurrent())
        pendingOperationAcks += 1
        let oldTimeline = playbackInfo.timeline
        let holders = addMediaSourceHolders(mediaSources, at: index)
        let newTimeline = createMaskingTimeline()
        let newPlaybackInfo = maskTimelineAndPosition(
            playbackInfo: playbackInfo,
            timeline: newTimeline,
            periodPositionUs: periodPositionUsAfterTimelineChanged(
                oldTimeline: oldTimeline,
                newTimeline: newTimeline,
                currentWindowIndexInternal: currentWindowIndexInternal(playbackInfo: playbackInfo),
                contentPositionMs: contentPositionInternal(playbackInfo: playbackInfo)
            )
        )

        internalPlayer.insertMediaSources(holders, at: index, shuffleOrder: _shufflerOrder)

        return newPlaybackInfo
    }

    private func removeMediaItemsInternal(playbackInfo: PlaybackInfo, range: Range<Int>) -> PlaybackInfo {
        assert(queue.isCurrent())
        let currentIndex = currentWindowIndexInternal(playbackInfo: playbackInfo) ?? .zero
        let contentPositionMs = contentPositionInternal(playbackInfo: playbackInfo)
        let oldTimeline = playbackInfo.timeline
        let currentMediaSourceCount = mediaSourceHolderSnapshots.count
        pendingOperationAcks += 1
        removeMediaSourceHolders(range: range)
        let newTimeline = createMaskingTimeline()
        var newPlaybackInfo = maskTimelineAndPosition(
            playbackInfo: playbackInfo,
            timeline: newTimeline,
            periodPositionUs: periodPositionUsAfterTimelineChanged(
                oldTimeline: oldTimeline,
                newTimeline: newTimeline,
                currentWindowIndexInternal: currentIndex,
                contentPositionMs: contentPositionMs
            )
        )

        if newPlaybackInfo.state != .idle, newPlaybackInfo.state != .ended,
           range.upperBound == currentMediaSourceCount,
           currentIndex >= newPlaybackInfo.timeline.windowCount() {
            newPlaybackInfo = mask(playbackState: .ended, playbackInfo: newPlaybackInfo)
        }

        internalPlayer.removeMediaSources(range: range, shuffleOrder: _shufflerOrder)
        return newPlaybackInfo
    }

    private func removeMediaSourceHolders(range: Range<Int>) {
        mediaSourceHolderSnapshots.removeSubrange(range)
        _shufflerOrder = _shufflerOrder.cloneAndRemove(
            indexFrom: range.lowerBound,
            indexToExclusive: range.upperBound
        )
    }

    private func createMaskingTimeline() -> Timeline {
        assert(queue.isCurrent())
        return PlaylistTimeline(
            mediaSourceInfoHolders: mediaSourceHolderSnapshots,
            shuffleOrder: _shufflerOrder
        )
    }

    private func maskTimelineAndPosition(
        playbackInfo: PlaybackInfo,
        timeline: Timeline,
        periodPositionUs: (id: AnyHashable, periodPositionUs: Int64)?
    ) -> PlaybackInfo {
        guard timeline.isEmpty || periodPositionUs != nil else {
            return playbackInfo
        }

        let oldTimeline = playbackInfo.timeline
        let oldContentPositionMs = contentPositionInternal(playbackInfo: playbackInfo)
        var playbackInfo = playbackInfo.timeline(timeline)

        if timeline.isEmpty {
            let dummyMediaPeriodId = PlaybackInfo.placeholderMediaPeriodId
            let positionUs = Time.msToUs(timeMs: maskingWindowPositionMs)
            playbackInfo = playbackInfo.positionUs(
                periodId: dummyMediaPeriodId,
                positionUs: positionUs,
                requestedContentPositionUs: positionUs,
                discontinuityStartPositionUs: positionUs,
                totalBufferedDurationUs: 0,
                trackGroups: [],
                trackSelectorResult: emptyTrackSelectorResult
            )
            playbackInfo = playbackInfo.loadingMediaPeriodId(dummyMediaPeriodId)
            playbackInfo.bufferedPositionUs = playbackInfo.positionUs
            return playbackInfo
        }

        guard let periodPositionUs else { return playbackInfo }
        let oldPeriodId = playbackInfo.periodId.periodId
        let playingPeriodChanged = oldPeriodId != periodPositionUs.id
        let newPeriodId = playingPeriodChanged ? MediaPeriodId(periodId: periodPositionUs.id) : playbackInfo.periodId
        let newContentPositionUs = periodPositionUs.periodPositionUs
        var oldContentPositionUs = Time.msToUs(timeMs: oldContentPositionMs)

        if !oldTimeline.isEmpty {
            oldContentPositionUs -= timeline.periodById(oldPeriodId, period: period).positionInWindowUs

            if !playingPeriodChanged, oldContentPositionUs - newContentPositionUs == 1 {
                let oldDurationUs = oldTimeline.periodById(oldPeriodId, period: period).durationUs
                let endOfSameStream = oldContentPositionUs == oldDurationUs
                if endOfSameStream {
                    oldContentPositionUs -= 1
                }
            }
        }

        if playingPeriodChanged || newContentPositionUs < oldContentPositionUs {
            // TODO: check is not ad
            playbackInfo = playbackInfo.positionUs(
                periodId: newPeriodId,
                positionUs: newContentPositionUs,
                requestedContentPositionUs: newContentPositionUs,
                discontinuityStartPositionUs: newContentPositionUs,
                totalBufferedDurationUs: 0,
                trackGroups: playingPeriodChanged ? [] : playbackInfo.trackGroups,
                trackSelectorResult: playingPeriodChanged ? emptyTrackSelectorResult : playbackInfo.trackSelectorResult
            )
            playbackInfo = playbackInfo.loadingMediaPeriodId(newPeriodId)
            playbackInfo.bufferedPositionUs = newContentPositionUs
        } else if newContentPositionUs == oldContentPositionUs {
            let loadingPeriodIndex = timeline.indexOfPeriod(by: playbackInfo.loadingMediaPeriodId.periodId)

            switch loadingPeriodIndex {
            case let .some(loadingPeriodIndex):
                let loadingWindowIndex = timeline.getPeriod(periodIndex: loadingPeriodIndex, period: period).windowIndex
                let newWindowIndex = timeline.periodById(newPeriodId.periodId, period: period).windowIndex
                if loadingWindowIndex != newWindowIndex { fallthrough }
            default:
                timeline.periodById(newPeriodId.periodId, period: period)
                let maskedBufferedPositionUs = period.durationUs

                playbackInfo = playbackInfo.positionUs(
                    periodId: newPeriodId,
                    positionUs: playbackInfo.positionUs,
                    requestedContentPositionUs: playbackInfo.positionUs,
                    discontinuityStartPositionUs: playbackInfo.discontinuityStartPositionUs,
                    totalBufferedDurationUs: maskedBufferedPositionUs - playbackInfo.positionUs,
                    trackGroups: playbackInfo.trackGroups,
                    trackSelectorResult: playbackInfo.trackSelectorResult
                )
                playbackInfo = playbackInfo.loadingMediaPeriodId(newPeriodId)
                playbackInfo.bufferedPositionUs = maskedBufferedPositionUs
            }
        } else {
            let maskedTotalBufferedDurationUs = max(0, playbackInfo.totalBufferedDurationUs - (newContentPositionUs - oldContentPositionUs))
            var maskedBufferedPositionUs = playbackInfo.bufferedPositionUs
            if playbackInfo.loadingMediaPeriodId == playbackInfo.periodId {
                maskedBufferedPositionUs = newContentPositionUs + maskedTotalBufferedDurationUs
            }

            playbackInfo = playbackInfo.positionUs(
                periodId: newPeriodId,
                positionUs: newContentPositionUs,
                requestedContentPositionUs: newContentPositionUs,
                discontinuityStartPositionUs: newContentPositionUs,
                totalBufferedDurationUs: maskedTotalBufferedDurationUs,
                trackGroups: playbackInfo.trackGroups,
                trackSelectorResult: playbackInfo.trackSelectorResult
            )

            playbackInfo.bufferedPositionUs = maskedBufferedPositionUs
        }

        return playbackInfo
    }

    private func mask(
        playbackState: PlayerState,
        playbackInfo: PlaybackInfo
    ) -> PlaybackInfo {
        var playbackInfo = playbackInfo.playbackState(playbackState)
        if playbackState == .idle || playbackState == .ended {
            playbackInfo = playbackInfo.isLoading(false)
        }
        return playbackInfo
    }

    private func periodPositionUsAfterTimelineChanged(
        oldTimeline: Timeline,
        newTimeline: Timeline,
        currentWindowIndexInternal: Int?,
        contentPositionMs: Int64
    ) -> (id: AnyHashable, periodPositionUs: Int64)? {
        guard !oldTimeline.isEmpty || !newTimeline.isEmpty, let currentWindowIndexInternal else {
            let isCleared = !oldTimeline.isEmpty && newTimeline.isEmpty
            return maskWindowPositionMsOrGetPeriodPositionUs(
                timeline: newTimeline,
                windowIndex: isCleared ? nil : currentWindowIndexInternal,
                windowPositionMs: isCleared ? .timeUnset : contentPositionMs
            )
        }

        guard let (oldPeriodId, oldPeriodPositionUs) = oldTimeline.periodPositionUs(
            window: window,
            period: period,
            windowIndex: currentWindowIndexInternal,
            windowPositionUs: Time.msToUs(timeMs: contentPositionMs)
        ) else { return nil }

        guard timeline.indexOfPeriod(by: oldPeriodId) != nil else {
            return (oldPeriodId, oldPeriodPositionUs)
        }

        if let newWindowIndex = internalPlayer.resolveSubsequentPeriod(
            window: window,
            period: period,
            repeatMode: _repeatMode,
            shuffleModeEnabled: _shuffleModeEnabled,
            oldPeriodId: oldPeriodId,
            oldTimeline: oldTimeline,
            newTimeline: newTimeline
        ) {
            return maskWindowPositionMsOrGetPeriodPositionUs(
                timeline: newTimeline,
                windowIndex: newWindowIndex,
                windowPositionMs: newTimeline.getWindow(windowIndex: newWindowIndex, window: window).defaultPositionUs
            )
        } else {
            return maskWindowPositionMsOrGetPeriodPositionUs(
                timeline: newTimeline,
                windowIndex: nil,
                windowPositionMs: .timeUnset
            )
        }
    }

    private func maskWindowPositionMsOrGetPeriodPositionUs(
        timeline: Timeline, windowIndex: Int?, windowPositionMs: Int64
    ) -> (id: AnyHashable, periodPositionUs: Int64)? {
        guard !timeline.isEmpty else {
            maskingWindowIndex = windowIndex
            maskingWindowPositionMs = windowPositionMs == .timeUnset ? .zero : windowPositionMs
            maskingPeriodIndex = 0
            return nil
        }

        let updatedWindowIndex: Int
        var windowPositionMs: Int64 = windowPositionMs

        switch windowIndex {
        case let .some(windowIndex):
            if windowIndex >= timeline.windowCount() { fallthrough }
            updatedWindowIndex = windowIndex
        default:
            guard let windowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) else {
                return nil
            }
            updatedWindowIndex = windowIndex
            windowPositionMs = timeline.getWindow(windowIndex: windowIndex, window: window).defaultPositionUs
        }

        return timeline.periodPositionUs(
            window: window,
            period: period,
            windowIndex: updatedWindowIndex,
            windowPositionUs: Time.msToUs(timeMs: windowPositionMs)
        )
    }

    private func periodPositionUs(to windowPositionUs: Int64, timeline: Timeline, periodId: MediaPeriodId) -> Int64 {
        assert(queue.isCurrent())
        timeline.periodById(periodId.periodId, period: period)
        return windowPositionUs + period.positionInWindowUs
    }

    private func createMessageInternal(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage {
        assert(queue.isCurrent())
        let defaultMediaItemIndex = if let currentWindowIndex = currentWindowIndexInternal(playbackInfo: playbackInfo) {
            currentWindowIndex
        } else {
            Int.zero
        }

        return PlayerMessage(
            sender: internalPlayer,
            target: handler,
            timeline: playbackInfo.timeline,
            defaultMediaItemIndex: defaultMediaItemIndex,
            clock: clock,
            defaultQueue: internalPlayer.queue
        )
    }

    private func updatePlayWhenReady(_ playWhenReady: Bool, changeReason: PlayWhenReadyChangeReason) {
        assert(queue.isCurrent())
        let playbackSuppressionReason = computePlaybackSuppressionReason(playWhenReady: playWhenReady)
        guard playbackInfo.playWhenReady != playWhenReady ||
              playbackInfo.playbackSuppressionReason != playbackSuppressionReason ||
              playbackInfo.playWhenReadyChangeReason != changeReason else {
            return
        }

        pendingOperationAcks += 1
        let newPlaybackInfo = playbackInfo.playWhenReady(
            playWhenReady,
            playWhenReadyChangeReason: changeReason,
            playbackSuppressionReason: playbackSuppressionReason
        )

        internalPlayer.setPlayWhenReady(
            playWhenReady,
            playWhenReadyChangeReason: changeReason,
            playbackSuppressionReason: playbackSuppressionReason
        )

        updatePlaybackInfo(
            new: newPlaybackInfo,
            timelineChangeReason: .playlistChanged,
            positionDiscontinuity: false,
            positionDiscontinuityReason: .internal,
            discontinuityWindowStartPositionUs: .timeUnset,
            oldMaskingMediaItemIndex: nil,
            repeatCurrentMediaItem: false
        )
    }

    private func computePlaybackSuppressionReason(playWhenReady: Bool) -> PlaybackSuppressionReason {
        assert(queue.isCurrent())
        // TODO: some stuff in future
        return .none
    }

    private func canUpdateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) -> Bool {
        assert(queue.isCurrent())
        guard range.count == mediaItems.count else { return false }

        for (offset, index) in range.enumerated() {
            if !mediaSourceHolderSnapshots[index].mediaSource.canUpdateMediaItem(new: mediaItems[offset]) {
                return false
            }
        }

        return true
    }

    private func updateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) {
        assert(queue.isCurrent())
        pendingOperationAcks += 1
        internalPlayer.updateMediaSources(with: mediaItems, range: range)
        for (offset, index) in range.enumerated() {
            mediaSourceHolderSnapshots[index].timeline = TimelineWithUpdatedMediaItem(
                timeline: mediaSourceHolderSnapshots[index].timeline,
                updatedMediaItem: mediaItems[offset]
            )
        }

        let newTimeline = createMaskingTimeline()
        let newPlaybackInfo = playbackInfo.timeline(newTimeline)
        updatePlaybackInfo(
            new: newPlaybackInfo,
            timelineChangeReason: .playlistChanged,
            positionDiscontinuity: false,
            positionDiscontinuityReason: .remove,
            discontinuityWindowStartPositionUs: .timeUnset,
            oldMaskingMediaItemIndex: nil,
            repeatCurrentMediaItem: false
        )
    }
}

extension SEPlayerImpl {
    func setVideoOutput(_ output: VideoSampleBufferRenderer) {
        internalPlayer.setVideoOutput(output)
    }

    func removeVideoOutput(_ output: VideoSampleBufferRenderer) {
        internalPlayer.removeVideoOutput(output)
    }
}

extension SEPlayerImpl: SEPlayerImplInternalDelegate {
    func onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate) {
        queue.async { self._onPlaybackInfoUpdate(playbackInfoUpdate: playbackInfoUpdate) }
    }

    func _onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate) {
        assert(queue.isCurrent())
        pendingOperationAcks -= playbackInfoUpdate.operationAcks
        if playbackInfoUpdate.positionDiscontinuity {
            pendingDiscontinuityReason = playbackInfoUpdate.discontinuityReason
            pendingDiscontinuity = true
        }

        if pendingOperationAcks == 0 {
            let newTimeline = playbackInfoUpdate.playbackInfo.timeline
            if !playbackInfo.timeline.isEmpty, newTimeline.isEmpty {
                maskingWindowIndex = nil
                maskingWindowPositionMs = 0
                maskingPeriodIndex = 0
            }

            if !newTimeline.isEmpty, let timelines = (newTimeline as? PlaylistTimeline)?.timelines,
               timelines.count == mediaSourceHolderSnapshots.count {
                for (index, timeline) in timelines.enumerated() {
                    mediaSourceHolderSnapshots[index].timeline = timeline
                }
            }

            var positionDiscontinuity = false
            var discontinuityWindowStartPositionUs = Int64.timeUnset

            if pendingDiscontinuity {
                positionDiscontinuity = playbackInfoUpdate.playbackInfo.periodId != playbackInfo.periodId ||
                    playbackInfoUpdate.playbackInfo.discontinuityStartPositionUs != playbackInfo.positionUs

                if positionDiscontinuity {
                    discontinuityWindowStartPositionUs = if newTimeline.isEmpty {
                        playbackInfoUpdate.playbackInfo.discontinuityStartPositionUs
                    } else {
                        periodPositionUs(
                            to: playbackInfoUpdate.playbackInfo.discontinuityStartPositionUs,
                            timeline: newTimeline,
                            periodId: playbackInfoUpdate.playbackInfo.periodId
                        )
                    }
                }
            }

            pendingDiscontinuity = false
            updatePlaybackInfo(
                new: playbackInfoUpdate.playbackInfo,
                timelineChangeReason: .sourceUpdate,
                positionDiscontinuity: positionDiscontinuity,
                positionDiscontinuityReason: pendingDiscontinuityReason,
                discontinuityWindowStartPositionUs: discontinuityWindowStartPositionUs,
                oldMaskingMediaItemIndex: nil,
                repeatCurrentMediaItem: false
            )
        }
    }
}

private struct MediaSourceHolderSnapshot: MediaSourceInfoHolder {
    let id: AnyHashable
    let mediaSource: MediaSource
    var timeline: Timeline

    init(id: AnyHashable, mediaSource: MaskingMediaSource) {
        self.id = id
        self.mediaSource = mediaSource
        self.timeline = mediaSource.timeline
    }
}
