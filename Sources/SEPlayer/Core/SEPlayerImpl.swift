//
//  SEPlayerImpl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

import AVFoundation
import SEPlayerCommon

final class SEPlayerImpl: BasePlayer, SEPlayer, @unchecked Sendable {
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

    let seekBackIncrement: CMTime
    let seekForwardIncrement: CMTime
    let maxSeekToPreviousPosition: CMTime

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

    var duration: CMTime { queue.sync { contentDuration } }

    var currentPosition: CMTime {
        queue.sync {
            currentPositionInternal(playbackInfo: playbackInfo)
        }
    }

    var bufferedPosition: CMTime { queue.sync { contentBufferedPosition } }

    var totalBufferedDuration: CMTime { queue.sync { playbackInfo.totalBufferedDuration } }

    var contentPosition: CMTime { queue.sync { contentPositionInternal(playbackInfo: playbackInfo) } }

    var contentBufferedPosition: CMTime { queue.sync { getContentBufferedPosition() } }

    var pauseAtTheEndOfMediaItem: Bool {
        get { queue.sync { _pauseAtTheEndOfMediaItem } }
        set { setPauseAtEndOfMediaItems(newValue) }
    }

    var window: Window

    private let queue: Queue
    private let workQueue: Queue
    private let mediaSourceFactory: MediaSourceFactory
    private let emptyTrackSelectorResult: TrackSelectorResult
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
    private var maskingWindowPosition: CMTime = .zero
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
        seekBackIncrement: CMTime = CMTime(seconds: 5, preferredTimescale: 1000),
        seekForwardIncrement: CMTime = CMTime(seconds: 5, preferredTimescale: 1000),
        maxSeekToPreviousPosition: CMTime = CMTime(seconds: 3, preferredTimescale: 1000),
        pauseAtTheEndOfMediaItem: Bool = false
    ) {
        self.workQueue = workQueue
        self.queue = applicationQueue
        self.clock = clock
        self.mediaSourceFactory = mediaSourceFactory
        self.useLazyPreparation = useLazyPreparation
        _seekParameters = seekParameters
        self.seekBackIncrement = seekBackIncrement
        self.seekForwardIncrement = seekForwardIncrement
        self.maxSeekToPreviousPosition = maxSeekToPreviousPosition
        _pauseAtTheEndOfMediaItem = pauseAtTheEndOfMediaItem

        let renderSynchronizer = AVSampleBufferRenderSynchronizer()
        self.renderers = renderersFactory.createRenderers(
            queue: workQueue,
            clock: clock,
            renderSynchronizer: renderSynchronizer
        )
        emptyTrackSelectorResult = TrackSelectorResult(
            rendererConfigurations: Array(repeating: nil, count: renderers.count),
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
                discontinuityWindowStartPosition: .invalid,
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

    func set(mediaItems: [MediaItem], startIndex: Int, startPosition: CMTime) {
        queue.async { [weak self] in
            guard let self else { return }

            set(
                mediaSources: createMediaSources(mediaItems: mediaItems),
                startMediaItemIndex: startIndex,
                startPosition: startPosition
            )
        }
    }

    func set(mediaSource: MediaSource) {
        set(mediaSources: [mediaSource])
    }

    func set(mediaSource: MediaSource, startPosition: CMTime) {
        set(
            mediaSources: [mediaSource],
            startMediaItemIndex: 0,
            startPosition: startPosition
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
                startPosition: .invalid,
                resetToDefaultPosition: resetPosition
            )
        }
    }

    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPosition: CMTime) {
        queue.async { [weak self] in
            guard let self else { return }

            setMediaSourcesInternal(
                mediaSources,
                startWindowIndex: startMediaItemIndex,
                startPosition: startPosition,
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
                discontinuityWindowStartPosition: .invalid,
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
                discontinuityWindowStartPosition: currentPositionInternal(playbackInfo: newPlaybackInfo),
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
                periodPosition: periodPositionAfterTimelineChanged(
                    oldTimeline: oldTimeline,
                    newTimeline: newTimeline,
                    currentWindowIndexInternal: currentWindowIndexInternal(playbackInfo: playbackInfo),
                    contentPosition: contentPositionInternal(playbackInfo: playbackInfo)
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
                discontinuityWindowStartPosition: .invalid,
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
                discontinuityWindowStartPosition: currentPositionInternal(playbackInfo: newPlaybackInfo),
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
                periodPosition: maskWindowPositionMsOrGetPeriodPosition(
                    timeline: timeline,
                    windowIndex: currentMediaItemIndex,
                    windowPosition: currentPosition
                )
            )
            pendingOperationAcks += 1
            internalPlayer.setShuffleOrder(shuffleOrder)
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: false,
                positionDiscontinuityReason: .internal,
                discontinuityWindowStartPosition: .invalid,
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

    func seek(to mediaItemIndex: Int?, position: CMTime, isRepeatingCurrentItem: Bool) {
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
                periodPosition: maskWindowPositionMsOrGetPeriodPosition(
                    timeline: timeline,
                    windowIndex: mediaItemIndex,
                    windowPosition: position
                )
            )
            self.internalPlayer.seekTo(
                timeline: timeline,
                windowIndex: mediaItemIndex,
                position: position
            )
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: true,
                positionDiscontinuityReason: .seek,
                discontinuityWindowStartPosition: currentPositionInternal(playbackInfo: playbackInfo),
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
                discontinuityWindowStartPosition: .invalid,
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

    private func getContentBufferedPosition() -> CMTime {
        assert(queue.isCurrent())
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowPosition
        }

        if playbackInfo.loadingMediaPeriodId.windowSequenceNumber != playbackInfo.periodId.windowSequenceNumber {
            return playbackInfo.timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).duration
        }

        
        return periodPosition(
            to: playbackInfo.bufferedPosition,
            timeline: playbackInfo.timeline,
            periodId: playbackInfo.loadingMediaPeriodId
        )
    }

    private func stopInternal(error: Error?) {
        assert(queue.isCurrent())
        var playbackInfo = playbackInfo.loadingMediaPeriodId(playbackInfo.periodId)
        playbackInfo.bufferedPosition = playbackInfo.position
        playbackInfo.totalBufferedDuration = .zero
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
            discontinuityWindowStartPosition: .invalid,
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

    func contentPositionInternal(playbackInfo: PlaybackInfo) -> CMTime {
        assert(queue.isCurrent())
        return currentPositionInternal(playbackInfo: playbackInfo)
    }

    func currentPositionInternal(playbackInfo: PlaybackInfo) -> CMTime {
        assert(queue.isCurrent())
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowPosition
        }

        return periodPosition(
            to: playbackInfo.position,
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
        discontinuityWindowStartPosition: CMTime,
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
            let positionInfo = positionInfo(for: discontinuityWindowStartPosition)
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

        let oldPosition: CMTime
        let oldContentPosition: CMTime

        if positionDiscontinuityReason == .autoTransition {
            oldPosition = oldPeriod.positionInWindow + oldPeriod.duration
            oldContentPosition = oldPosition
        } else {
            oldPosition = oldPeriod.positionInWindow + oldPlaybackInfo.position
            oldContentPosition = oldPosition
        }

        return PositionInfo(
            windowId: oldWindowId,
            mediaItemIndex: oldMediaItemIndex,
            mediaItem: oldMediaItem,
            periodId: oldPeriodId,
            periodIndex: oldPeriodIndex,
            position: oldPosition,
            contentPosition: oldContentPosition
        )
    }

    private func positionInfo(for discontinuityWindowStartPosition: CMTime) -> PositionInfo {
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

        return PositionInfo(
            windowId: newWindowId,
            mediaItemIndex: newMediaItemIndex,
            mediaItem: newMediaItem,
            periodId: newPeriodId,
            periodIndex: newPeriodIndex,
            position: discontinuityWindowStartPosition,
            contentPosition: discontinuityWindowStartPosition
        )
    }

    private func requestedContentPosition(playbackInfo: PlaybackInfo) -> CMTime {
        assert(queue.isCurrent())
        let window = Window()
        let period = Period()
        playbackInfo.timeline.periodById(playbackInfo.periodId.periodId, period: period)

        if playbackInfo.requestedContentPosition.isValid == false {
            return playbackInfo.timeline.getWindow(windowIndex: period.windowIndex, window: window).defaultPosition
        } else {
            return period.positionInWindow + playbackInfo.requestedContentPosition
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
        startPosition: CMTime,
        resetToDefaultPosition: Bool
    ) {
        assert(queue.isCurrent())
        var startWindowIndex = startWindowIndex
        var startPosition = startPosition
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
            startPosition = .invalid
        } else if startWindowIndex == nil {
            startWindowIndex = currentWindowIndex
            startPosition = currentPosition
        }

        var newPlaybackInfo = maskTimelineAndPosition(
            playbackInfo: playbackInfo,
            timeline: timeline,
            periodPosition: maskWindowPositionMsOrGetPeriodPosition(
                timeline: timeline,
                windowIndex: startWindowIndex,
                windowPosition: startPosition
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
            position: startPosition,
            shuffleOrder: _shufflerOrder
        )

        let positionDiscontinuity = playbackInfo.periodId.periodId != newPlaybackInfo.periodId.periodId && !playbackInfo.timeline.isEmpty
        updatePlaybackInfo(
            new: newPlaybackInfo,
            timelineChangeReason: .playlistChanged,
            positionDiscontinuity: positionDiscontinuity,
            positionDiscontinuityReason: .remove,
            discontinuityWindowStartPosition: currentPositionInternal(playbackInfo: newPlaybackInfo),
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
            periodPosition: periodPositionAfterTimelineChanged(
                oldTimeline: oldTimeline,
                newTimeline: newTimeline,
                currentWindowIndexInternal: currentWindowIndexInternal(playbackInfo: playbackInfo),
                contentPosition: contentPositionInternal(playbackInfo: playbackInfo)
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
            periodPosition: periodPositionAfterTimelineChanged(
                oldTimeline: oldTimeline,
                newTimeline: newTimeline,
                currentWindowIndexInternal: currentIndex,
                contentPosition: contentPosition
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
        periodPosition: (id: AnyHashable, periodPosition: CMTime)?
    ) -> PlaybackInfo {
        guard timeline.isEmpty || periodPosition != nil else {
            assertionFailure()
            return playbackInfo
        }

        let oldTimeline = playbackInfo.timeline
        var oldContentPosition = contentPositionInternal(playbackInfo: playbackInfo)
        var playbackInfo = playbackInfo.timeline(timeline)

        if timeline.isEmpty {
            let dummyMediaPeriodId = PlaybackInfo.placeholderMediaPeriodId
            let position = maskingWindowPosition
            playbackInfo = playbackInfo.setPosition(
                periodId: dummyMediaPeriodId,
                position: position,
                requestedContentPosition: position,
                discontinuityStartPosition: position,
                totalBufferedDuration: .zero,
                trackGroups: .empty,
                trackSelectorResult: emptyTrackSelectorResult
            )
            playbackInfo = playbackInfo.loadingMediaPeriodId(dummyMediaPeriodId)
            playbackInfo.bufferedPosition = playbackInfo.position
            return playbackInfo
        }

        guard let periodPosition else { return playbackInfo }
        let oldPeriodId = playbackInfo.periodId.periodId
        let playingPeriodChanged = oldPeriodId != periodPosition.id
        let newPeriodId = playingPeriodChanged ? MediaPeriodId(periodId: periodPosition.id) : playbackInfo.periodId
        let newContentPosition = periodPosition.periodPosition

        if !oldTimeline.isEmpty {
            oldContentPosition = oldContentPosition - oldTimeline.periodById(oldPeriodId, period: period).positionInWindow

            if !playingPeriodChanged {
                let diff = oldContentPosition - newContentPosition
                // Check if off by one tick (the duration-1 clamp artifact)
                if diff == CMTime(value: 1, timescale: oldContentPosition.timescale) {
                    let oldDuration = oldTimeline.periodById(oldPeriodId, period: period).duration
                    if oldContentPosition == oldDuration {
                        oldContentPosition = oldContentPosition - CMTime(value: 1, timescale: oldContentPosition.timescale)
                    }
                }
            }
        }

        if playingPeriodChanged || newContentPosition < oldContentPosition {
            //TODO: assert(!newPeriodId.isAd)
            playbackInfo = playbackInfo.setPosition(
                periodId: newPeriodId,
                position: newContentPosition,
                requestedContentPosition: newContentPosition,
                discontinuityStartPosition: newContentPosition,
                totalBufferedDuration: .zero,
                trackGroups: playingPeriodChanged ? .empty : playbackInfo.trackGroups,
                trackSelectorResult: playingPeriodChanged ? emptyTrackSelectorResult : playbackInfo.trackSelectorResult
            )
            playbackInfo = playbackInfo.loadingMediaPeriodId(newPeriodId)
            playbackInfo.bufferedPosition = newContentPosition
        } else if newContentPosition == oldContentPosition {
            let loadingPeriodIndex = timeline.indexOfPeriod(by: playbackInfo.loadingMediaPeriodId.periodId)

            switch loadingPeriodIndex {
            case let .some(loadingPeriodIndex):
                let loadingWindowIndex = timeline.getPeriod(periodIndex: loadingPeriodIndex, period: period).windowIndex
                let newWindowIndex = timeline.periodById(newPeriodId.periodId, period: period).windowIndex
                if loadingWindowIndex != newWindowIndex { fallthrough }
            default:
                timeline.periodById(newPeriodId.periodId, period: period)
                let maskedBufferedPosition: CMTime
//               TODO: if newPeriodId.isAd {
//                    maskedBufferedPosition = period.adDuration(adGroupIndex: newPeriodId.adGroupIndex, adIndexInAdGroup: newPeriodId.adIndexInAdGroup)
//                } else {
//                    maskedBufferedPosition = period.duration
//                }
                maskedBufferedPosition = period.duration

                playbackInfo = playbackInfo.setPosition(
                    periodId: newPeriodId,
                    position: playbackInfo.position,
                    requestedContentPosition: playbackInfo.position,
                    discontinuityStartPosition: playbackInfo.discontinuityStartPosition,
                    totalBufferedDuration: maskedBufferedPosition - playbackInfo.position,
                    trackGroups: playbackInfo.trackGroups,
                    trackSelectorResult: playbackInfo.trackSelectorResult
                )
                playbackInfo = playbackInfo.loadingMediaPeriodId(newPeriodId)
                playbackInfo.bufferedPosition = maskedBufferedPosition
            }
        } else {
            // TODO: assert(!newPeriodId.isAd)
            let maskedTotalBufferedDuration = max(.zero, playbackInfo.totalBufferedDuration - (newContentPosition - oldContentPosition))
            var maskedBufferedPosition = playbackInfo.bufferedPosition
            if playbackInfo.loadingMediaPeriodId == playbackInfo.periodId {
                maskedBufferedPosition = newContentPosition + maskedTotalBufferedDuration
            }

            playbackInfo = playbackInfo.setPosition(
                periodId: newPeriodId,
                position: newContentPosition,
                requestedContentPosition: newContentPosition,
                discontinuityStartPosition: newContentPosition,
                totalBufferedDuration: maskedTotalBufferedDuration,
                trackGroups: playbackInfo.trackGroups,
                trackSelectorResult: playbackInfo.trackSelectorResult
            )
            playbackInfo.bufferedPosition = maskedBufferedPosition
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

    private func periodPositionAfterTimelineChanged(
        oldTimeline: Timeline,
        newTimeline: Timeline,
        currentWindowIndexInternal: Int?,
        contentPosition: CMTime
    ) -> (id: AnyHashable, periodPosition: CMTime)? {
        if oldTimeline.isEmpty || newTimeline.isEmpty {
            let isCleared = !oldTimeline.isEmpty && newTimeline.isEmpty
            return maskWindowPositionMsOrGetPeriodPosition(
                timeline: newTimeline,
                windowIndex: isCleared ? nil : currentWindowIndexInternal,
                windowPosition: isCleared ? .invalid : contentPosition
            )
        }

        guard let currentWindowIndexInternal else {
            return nil
        }

        guard let (oldPeriodId, oldPeriodPosition) = oldTimeline.periodPosition(
            window: window,
            period: period,
            windowIndex: currentWindowIndexInternal,
            windowPosition: contentPosition
        ) else { return nil }

        guard timeline.indexOfPeriod(by: oldPeriodId) != nil else {
            return (oldPeriodId, oldPeriodPosition)
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
            return maskWindowPositionMsOrGetPeriodPosition(
                timeline: newTimeline,
                windowIndex: newWindowIndex,
                windowPosition: newTimeline.getWindow(windowIndex: newWindowIndex, window: window).defaultPosition
            )
        } else {
            return maskWindowPositionMsOrGetPeriodPosition(
                timeline: newTimeline,
                windowIndex: nil,
                windowPosition: .invalid
            )
        }
    }

    private func maskWindowPositionMsOrGetPeriodPosition(
        timeline: Timeline, windowIndex: Int?, windowPosition: CMTime
    ) -> (id: AnyHashable, periodPosition: CMTime)? {
        guard !timeline.isEmpty else {
            maskingWindowIndex = windowIndex
            maskingWindowPosition = windowPosition.isValid ? windowPosition : .zero
            maskingPeriodIndex = 0
            return nil
        }

        let updatedWindowIndex: Int
        var windowPosition: CMTime = windowPosition

        switch windowIndex {
        case let .some(windowIndex):
            if windowIndex >= timeline.windowCount() { fallthrough }
            updatedWindowIndex = windowIndex
        default:
            guard let windowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled) else {
                return nil
            }
            updatedWindowIndex = windowIndex
            windowPosition = timeline.getWindow(windowIndex: windowIndex, window: window).defaultPosition
        }

        return timeline.periodPosition(
            window: window,
            period: period,
            windowIndex: updatedWindowIndex,
            windowPosition: windowPosition
        )
    }

    private func periodPosition(to windowPosition: CMTime, timeline: Timeline, periodId: MediaPeriodId) -> CMTime {
        assert(queue.isCurrent())
        timeline.periodById(periodId.periodId, period: period)
        return windowPosition + period.positionInWindow
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
            discontinuityWindowStartPosition: .invalid,
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
            discontinuityWindowStartPosition: .invalid,
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
                maskingWindowPosition = .zero
                maskingPeriodIndex = 0
            }

            if !newTimeline.isEmpty, let timelines = (newTimeline as? PlaylistTimeline)?.timelines,
               timelines.count == mediaSourceHolderSnapshots.count {
                for (index, timeline) in timelines.enumerated() {
                    mediaSourceHolderSnapshots[index].timeline = timeline
                }
            }

            var positionDiscontinuity = false
            var discontinuityWindowStartPosition = CMTime.invalid

            if pendingDiscontinuity {
                positionDiscontinuity = playbackInfoUpdate.playbackInfo.periodId != playbackInfo.periodId ||
                    playbackInfoUpdate.playbackInfo.discontinuityStartPosition != playbackInfo.position

                if positionDiscontinuity {
                    discontinuityWindowStartPosition = if newTimeline.isEmpty {
                        playbackInfoUpdate.playbackInfo.discontinuityStartPosition
                    } else {
                        periodPosition(
                            to: playbackInfoUpdate.playbackInfo.discontinuityStartPosition,
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
                discontinuityWindowStartPosition: discontinuityWindowStartPosition,
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
