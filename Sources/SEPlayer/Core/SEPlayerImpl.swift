//
//  SEPlayerImpl.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 22.05.2025.
//

// swiftlint:disable file_length

import AVFoundation
import SEPlayerCommon

/// Usable from any thread. A lock guards its state: each call runs at once, under it, and so do the updates from the
/// playback queue. The delegates hear the changes on the main queue, in order.
final class SEPlayerImpl: BasePlayer, SEPlayer, @unchecked Sendable {
    @MainActor let delegate = MulticastDelegate<SEPlayerDelegate>(isThreadSafe: false)

    let clock: SEClock
    let timebase: CMTimebase
    let bandwidthMeter: BandwidthMeter
    var playbackState: PlayerState { lock.withLock { playbackInfo.state } }

    var isPlaying: Bool { lock.withLock { playbackInfo.isPlaying } }

    var playWhenReady: Bool {
        get { lock.withLock { playbackInfo.playWhenReady } }
        set { setPlayWhenReady(newValue) }
    }

    var repeatMode: RepeatMode {
        get { lock.withLock { _repeatMode } }
        set { setRepeatMode(newValue) }
    }

    var shuffleModeEnabled: Bool {
        get { lock.withLock { _shuffleModeEnabled } }
        set { setShuffleModeEnabled(newValue) }
    }

    var volume: Float {
        get { lock.withLock { internalPlayer.volume } }
        set {
            let volume = min(max(newValue, 0), 1)
            lock.withLock {
                guard internalPlayer.volume != volume else { return }
                internalPlayer.volume = volume
                reportAudioSessionUsage()
                DispatchQueue.main.async { [self] in
                    delegate.invokeDelegates { $0.player(self, didChangeVolume: volume) }
                }
            }
        }
    }

    var isMuted: Bool {
        get { lock.withLock { internalPlayer.isMuted } }
        set {
            lock.withLock {
                guard internalPlayer.isMuted != newValue else { return }
                internalPlayer.isMuted = newValue
                reportAudioSessionUsage()
                DispatchQueue.main.async { [self] in
                    delegate.invokeDelegates { $0.player(self, didChangeIsMuted: newValue) }
                }
            }
        }
    }

    var audioSessionPolicy: AudioSessionPolicy {
        get { lock.withLock { _audioSessionPolicy } }
        set {
            lock.withLock {
                guard _audioSessionPolicy != newValue else { return }
                _audioSessionPolicy = newValue
                reportAudioSessionUsage()
            }
        }
    }

    var mediaMetadata: MediaMetadata { lock.withLock { _mediaMetadata } }

    var playlistMetadata: MediaMetadata {
        get { lock.withLock { _playlistMetadata } }
        set {
            lock.withLock {
                guard _playlistMetadata != newValue else { return }
                _playlistMetadata = newValue
                DispatchQueue.main.async { [self] in
                    delegate.invokeDelegates { $0.player(self, didChangePlaylistMetadata: newValue) }
                }
            }
        }
    }

    var videoSize: VideoSize { lock.withLock { _videoSize } }

    var videoFormat: AnyFormat? { lock.withLock { _videoFormat } }

    var audioFormat: AnyFormat? { lock.withLock { _audioFormat } }

    var isLoading: Bool { lock.withLock { playbackInfo.isLoading } }

    let seekBackIncrement: CMTime
    let seekForwardIncrement: CMTime
    let maxSeekToPreviousPosition: CMTime

    var playbackParameters: PlaybackParameters {
        get { lock.withLock { playbackInfo.playbackParameters } }
        set { setPlaybackParameters(newValue) }
    }

    var timeline: Timeline { lock.withLock { playbackInfo.timeline } }

    var currentPeriodIndex: Int? {
        lock.withLock {
            if playbackInfo.timeline.isEmpty {
                // Before there is a timeline, a seek's window stands for its period.
                maskingWindowIndex ?? 0
            } else {
                playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId)
            }
        }
    }

    var preloadConfiguration: PreloadConfiguration {
        get { lock.withLock { _preloadConfiguration } }
        set { setPreloadConfiguration(newValue) }
    }

    var currentMediaItemIndex: Int {
        lock.withLock { currentWindowIndexInternal(playbackInfo: playbackInfo) ?? .zero }
    }

    var duration: CMTime { lock.withLock { contentDuration } }

    var currentPosition: CMTime {
        lock.withLock {
            // TODO: go to player
            currentPositionInternal(playbackInfo: playbackInfo)
        }
    }

    var bufferedPosition: CMTime { lock.withLock { contentBufferedPosition } }

    var totalBufferedDuration: CMTime { lock.withLock { totalBufferedDurationInternal(playbackInfo: playbackInfo) } }

    var contentPosition: CMTime {
        // TODO: ad
        lock.withLock { contentPositionInternal(playbackInfo: playbackInfo) }
    }

    var contentBufferedPosition: CMTime { lock.withLock { getContentBufferedPosition() } }

    var pauseAtTheEndOfMediaItem: Bool {
        get { lock.withLock { _pauseAtTheEndOfMediaItem } }
        set { setPauseAtEndOfMediaItems(newValue) }
    }

    var scrubbingModeEnabled: Bool {
        get { lock.withLock { _scrubbingModeEnabled } }
        set {
            lock.withLock {
                guard _scrubbingModeEnabled != newValue else { return }
                _scrubbingModeEnabled = newValue
                internalPlayer.setScrubbingModeEnabled(newValue)
            }
        }
    }

    var window: Window

    func withConsistentState<R>(_ body: () throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    /// Guards the state. Recursive: a call may use others, as the navigation of ``BasePlayer`` does.
    private let lock = NSRecursiveLock()
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
    private var _shufflerOrder: ShuffleOrder
    private var _preloadConfiguration: PreloadConfiguration
    private var _pauseAtTheEndOfMediaItem: Bool
    private var _mediaMetadata: MediaMetadata = .empty
    /// The timed metadata of the current item so far, which updates its media metadata, such as ICY titles.
    private var dynamicMetadata: [Metadata] = []
    private var _playlistMetadata: MediaMetadata = .empty
    private var _videoSize: VideoSize = .unknown
    private var _videoFormat: AnyFormat?
    private var _audioFormat: AnyFormat?

    private var maskingWindowIndex: Int?
    private var maskingWindowPosition: CMTime = .zero
    private var pendingOperationAcks: Int = 0
    private var pendingDiscontinuityReason: DiscontinuityReason = .autoTransition
    private var pendingDiscontinuity: Bool = false

    private var timeObservers = Set<TimebaseTimeObserver>()

    private let componentListener = ComponentListener()
    private let trackSelector: TrackSelector
    /// The size each video output shows the picture at, by output. Guarded by videoOutputSizesLock.
    private var videoOutputSizes = [ObjectIdentifier: CGSize]()
    private let videoOutputSizesLock = UnfairLock()

    private let identifier: UUID
    private let audioSessionController: AudioSessionController
    private var _audioSessionPolicy: AudioSessionPolicy = .movie
    private var _scrubbingModeEnabled = false
    /// What the audio session last allowed audible playback.
    private var audioSessionCommand: AudioSessionCommand = .play
    private var reportedAudioSessionUsage: AudioSessionUsage?
    @MainActor private(set) var currentCues: CueGroup = .emptyTimeZero

    init(
        identifier: UUID,
        workQueue: Queue,
        clock: SEClock,
        renderersFactory: RenderersFactory,
        trackSelector: TrackSelector,
        loadControl: LoadControl,
        bandwidthMeter: BandwidthMeter,
        mediaSourceFactory: MediaSourceFactory,
        audioSessionController: AudioSessionController,
        useLazyPreparation: Bool = true,
        seekBackIncrement: CMTime = CMTime(seconds: 5, preferredTimescale: 1000),
        seekForwardIncrement: CMTime = CMTime(seconds: 5, preferredTimescale: 1000),
        maxSeekToPreviousPosition: CMTime = CMTime(seconds: 1, preferredTimescale: 1000),
        pauseAtTheEndOfMediaItem: Bool = false
    ) throws {
        self.identifier = identifier
        self.audioSessionController = audioSessionController
        self.workQueue = workQueue
        self.clock = clock
        self.bandwidthMeter = bandwidthMeter
        self.mediaSourceFactory = mediaSourceFactory
        self.trackSelector = trackSelector
        self.useLazyPreparation = useLazyPreparation
        self.seekBackIncrement = seekBackIncrement
        self.seekForwardIncrement = seekForwardIncrement
        self.maxSeekToPreviousPosition = maxSeekToPreviousPosition
        _pauseAtTheEndOfMediaItem = pauseAtTheEndOfMediaItem
        timebase = try CMTimebase(sourceClock: .hostTimeClock)

        let renderSynchronizer = renderersFactory.makeSynchronizer()
        self.renderers = renderersFactory.createRenderers(
            queue: workQueue,
            clock: clock,
            renderSynchronizer: renderSynchronizer,
            textOutput: componentListener,
            metadataOutput: componentListener,
            videoListener: componentListener,
            audioListener: componentListener
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

        internalPlayer = try SEPlayerImplInternal(
            queue: workQueue,
            renderers: renderers,
            trackSelector: trackSelector,
            emptyTrackSelectorResult: emptyTrackSelectorResult,
            loadControl: loadControl,
            bandwidthMeter: bandwidthMeter,
            repeatMode: _repeatMode,
            shuffleModeEnabled: _shuffleModeEnabled,
            pauseAtEndOfWindow: pauseAtTheEndOfMediaItem,
            clock: clock,
            outboundTimebase: timebase,
            mediaClock: DefaultMediaClock(clock: clock, outboundTimebase: timebase, renderSynchronizer: clock.runsOnRenderSynchronizer ? renderSynchronizer : nil),
            identifier: identifier,
            preloadConfiguration: _preloadConfiguration
        )

        internalPlayer.playbackInfoUpdateListener = self
        componentListener.player = self
        audioSessionController.register(self, id: identifier)
    }

    func prepare() {
        lock.withLock {
            guard playbackInfo.state == .idle else { return }
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
        lock.withLock {
            set(
                mediaSources: createMediaSources(mediaItems: mediaItems),
                resetPosition: resetPosition
            )
        }
    }

    func set(mediaItems: [MediaItem], startIndex: Int, startPosition: CMTime) {
        lock.withLock {
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
        lock.withLock {
            setMediaSourcesInternal(
                mediaSources,
                startWindowIndex: nil,
                startPosition: .invalid,
                resetToDefaultPosition: resetPosition
            )
        }
    }

    func set(mediaSources: [MediaSource], startMediaItemIndex: Int, startPosition: CMTime) {
        lock.withLock {
            setMediaSourcesInternal(
                mediaSources,
                startWindowIndex: startMediaItemIndex,
                startPosition: startPosition,
                resetToDefaultPosition: false
            )
        }
    }

    func insert(mediaItems: [MediaItem], at position: Int) {
        lock.withLock {
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
        lock.withLock {
            insert(
                mediaSources: mediaSources,
                at: mediaSourceHolderSnapshots.count
            )
        }
    }

    func insert(mediaSources: [MediaSource], at index: Int) {
        lock.withLock {
            guard index >= 0 else { return }

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
        lock.withLock {
            let playlistSize = mediaSourceHolderSnapshots.count
            let clampedRange = range.lowerBound ..< min(range.upperBound, playlistSize)
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
        lock.withLock {
            let playlistSize = mediaSourceHolderSnapshots.count
            let fromIndex = range.lowerBound
            let toIndex = min(range.upperBound, playlistSize)
            let clampedRange = fromIndex ..< toIndex
            let itemCount = clampedRange.count
            let adjustedNewIndex = min(newIndex, playlistSize - itemCount)

            guard fromIndex < playlistSize || fromIndex != toIndex || fromIndex != adjustedNewIndex else {
                return
            }

            let oldTimeline = timeline
            pendingOperationAcks += 1
            let finalInsertIndex = adjustedNewIndex > fromIndex ? adjustedNewIndex - itemCount : adjustedNewIndex
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) {
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
        lock.withLock {
            guard range.upperBound < mediaSourceHolderSnapshots.count else {
                return
            }

            let clampedRange = range.lowerBound ..< min(range.upperBound, mediaSourceHolderSnapshots.count)

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
        lock.withLock {
            guard shuffleOrder.count == mediaSourceHolderSnapshots.count else {
                return
            }
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
        lock.withLock {
            guard _pauseAtTheEndOfMediaItem != pauseAtEndOfMediaItems else {
                return
            }
            _pauseAtTheEndOfMediaItem = pauseAtEndOfMediaItems
            internalPlayer.setPauseAtEndOfWindow(pauseAtEndOfMediaItems)
        }
    }

    private func setPlayWhenReady(_ playWhenReady: Bool) {
        lock.withLock {
            if playWhenReady, audioSessionCommand == .wait {
                // Asked to play while it waits for the session, as after an interruption: the session is set up
                // for it again, and refuses if it still can't play.
                audioSessionCommand = .play
                audioSessionController.resume(id: identifier)
            }
            updatePlayWhenReady(playWhenReady, changeReason: .userRequest)
        }
    }

    private func setRepeatMode(_ repeatMode: RepeatMode) {
        lock.withLock {
            guard _repeatMode != repeatMode else { return }
            _repeatMode = repeatMode
            internalPlayer.setRepeatMode(repeatMode)
        }
    }

    private func setShuffleModeEnabled(_ enabled: Bool) {
        lock.withLock {
            guard _shuffleModeEnabled != enabled else { return }
            _shuffleModeEnabled = enabled
            internalPlayer.setShuffleModeEnabled(enabled)
        }
    }

    private func setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration) {
        lock.withLock {
            guard _preloadConfiguration != preloadConfiguration else { return }
            _preloadConfiguration = preloadConfiguration
            internalPlayer.setPreloadConfiguration(preloadConfiguration)
        }
    }

    func seek(
        to mediaItemIndex: Int?,
        position: CMTime,
        isRepeatingCurrentItem: Bool,
        seekParameters: SeekParameters,
        completion: ((Bool) -> Void)?
    ) {
        lock.withLock {
            guard let mediaItemIndex, mediaItemIndex >= 0 else {
                completion?(false)
                return
            }

            let timeline = playbackInfo.timeline
            if !timeline.isEmpty && mediaItemIndex >= timeline.windowCount() {
                completion?(false)
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
            internalPlayer.seekTo(
                timeline: timeline,
                windowIndex: mediaItemIndex,
                position: position,
                seekParameters: seekParameters,
                completion: completion
            )

            // Show the target right away. The player queue sets the exact time once the seek runs;
            // other updates leave the timebase alone, as their positions are already out of date.
            try? timebase.setTime(to: newPlaybackInfo.position)

            SELogger.debug(.seek, "Seek requested to \(position.seconds) in item \(mediaItemIndex)")
            updatePlaybackInfo(
                new: newPlaybackInfo,
                timelineChangeReason: .playlistChanged,
                positionDiscontinuity: true,
                positionDiscontinuityReason: .seek,
                discontinuityWindowStartPosition: currentPositionInternal(playbackInfo: newPlaybackInfo),
                oldMaskingMediaItemIndex: oldMaskingMediaItemIndex,
                repeatCurrentMediaItem: isRepeatingCurrentItem
            )
        }
    }

    private func setPlaybackParameters(_ playbackParameters: PlaybackParameters) {
        lock.withLock {
            guard playbackInfo.playbackParameters != playbackParameters else {
                return
            }

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

    func stop() {
        lock.withLock {
            self.stopInternal(error: nil)
        }
    }

    func releaseAsync() async {
        audioSessionController.unregister(id: identifier)
        await internalPlayer.release()
        lock.withLock {
            playbackInfo = mask(playbackState: .idle, playbackInfo: playbackInfo)
            playbackInfo = playbackInfo.loadingMediaPeriodId(playbackInfo.periodId)
        }
    }

    func createMessage(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage {
        lock.withLock { createMessageInternal(handler: handler) }
    }

    /// The playback info comes from the last update from the playback queue, which has no timer and
    /// does not update while media just plays. Playback has moved on since by what the timebase
    /// shows, and that much of the buffer has been played.
    private func totalBufferedDurationInternal(playbackInfo: PlaybackInfo) -> CMTime {
        guard !playbackInfo.timeline.isEmpty,
              playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId) != nil else {
            return playbackInfo.totalBufferedDuration
        }

        let positionInWindow = playbackInfo.timeline.periodById(playbackInfo.periodId.periodId, period: period).positionInWindow
        let periodPosition = contentPositionInternal(playbackInfo: playbackInfo) - positionInWindow
        let played = max(.zero, periodPosition - playbackInfo.position)
        return max(.zero, playbackInfo.totalBufferedDuration - played)
    }

    private func getContentBufferedPosition() -> CMTime {
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowPosition
        }

        if playbackInfo.loadingMediaPeriodId.windowSequenceNumber != playbackInfo.periodId.windowSequenceNumber {
            return playbackInfo.timeline.getWindow(windowIndex: currentMediaItemIndex, window: window).duration
        }

        return windowPosition(
            ofPeriodPosition: playbackInfo.bufferedPosition,
            timeline: playbackInfo.timeline,
            periodId: playbackInfo.loadingMediaPeriodId
        )
    }

    private func stopInternal(error: Error?) {
        var playbackInfo = playbackInfo.loadingMediaPeriodId(playbackInfo.periodId)
        playbackInfo.bufferedPosition = timebase.time
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

    /// The metadata of the selected tracks and the timed metadata so far, under that of the media item.
    private func mediaMetadataInternal(playbackInfo: PlaybackInfo) -> MediaMetadata {
        guard !playbackInfo.timeline.isEmpty, let windowIndex = currentWindowIndexInternal(playbackInfo: playbackInfo) else {
            return .empty
        }
        let staticMetadata = playbackInfo.trackSelectorResult.selections.compactMap { $0?.format(for: 0).metadata }
        let mediaItem = playbackInfo.timeline.getWindow(windowIndex: windowIndex, window: window).mediaItem
        return MediaMetadata.Builder()
            .populate(from: staticMetadata)
            .populate(from: dynamicMetadata)
            .populate(from: mediaItem.mediaMetadata)
            .build()
    }

    /// Updates the media metadata with timed metadata the renderers output.
    private func addDynamicMetadata(_ metadata: Metadata) {
        lock.withLock {
            dynamicMetadata.append(metadata)
            let mediaMetadata = mediaMetadataInternal(playbackInfo: playbackInfo)
            let hasChanged = mediaMetadata != _mediaMetadata
            if hasChanged {
                _mediaMetadata = mediaMetadata
                SELogger.debug(.events, "Media metadata changed")
            }
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didReceiveMetadata: metadata) }
                guard hasChanged else { return }
                delegate.invokeDelegates { $0.player(self, didChangeMediaMetadata: mediaMetadata) }
            }
        }
    }

    private func currentWindowIndexInternal(playbackInfo: PlaybackInfo) -> Int? {
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowIndex
        }

        return playbackInfo.timeline
            .periodById(playbackInfo.periodId.periodId, period: period).windowIndex
    }

    func contentPositionInternal(playbackInfo: PlaybackInfo) -> CMTime {
        currentPositionInternal(playbackInfo: playbackInfo)
    }

    func currentPositionInternal(playbackInfo: PlaybackInfo) -> CMTime {
        guard !playbackInfo.timeline.isEmpty else {
            return maskingWindowPosition
        }

        // The position stops with `pause()`, not once the playback queue has got
        // to it: until then the timebase still runs. The masked position is where it paused.
        let position = playbackInfo.playWhenReady ? timebase.time : playbackInfo.position
        return windowPosition(
            ofPeriodPosition: position,
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
        let previousPlaybackInfo = self.playbackInfo
        let newPlaybackInfo = playbackInfo
        self.playbackInfo = playbackInfo
        reportAudioSessionUsage()

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
            // The timed metadata belongs to the item that played.
            dynamicMetadata.removeAll()
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
            SELogger.info(.events, "Timeline changed: \(newPlaybackInfo.timeline.windowCount()) windows, reason \(timelineChangeReason)")
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
            SELogger.info(.events, "Position discontinuity \(positionDiscontinuityReason): \(previousPositionInfo.position.seconds) → \(positionInfo.position.seconds)")
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
            SELogger.info(.events, "Media item transition, reason \(mediaItemTransitionReason.map { "\($0)" } ?? "none")")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didTransitionMediaItem: mediaItem, reason: mediaItemTransitionReason)
                }
            }
        }

        // The current item changes, or its metadata with a replaced item.
        let newMediaMetadata = mediaMetadataInternal(playbackInfo: newPlaybackInfo)
        if newMediaMetadata != _mediaMetadata {
            _mediaMetadata = newMediaMetadata
            SELogger.debug(.events, "Media metadata changed")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeMediaMetadata: newMediaMetadata) }
            }
        }

        if (previousPlaybackInfo.playbackError == nil && newPlaybackInfo.playbackError != nil) ||
            (previousPlaybackInfo.playbackError != nil && newPlaybackInfo.playbackError == nil) {
            if let error = newPlaybackInfo.playbackError {
                SELogger.error(.events, "Player error: \(error)")
            } else {
                SELogger.info(.events, "Player error cleared")
            }
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
            trackSelector.onSelectionActivated(info: newPlaybackInfo.trackSelectorResult.info)
            let tracks = newPlaybackInfo.trackSelectorResult.tracks
            SELogger.info(.events, "Tracks changed: \(tracks.groups.count) groups")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeTracks: tracks) }
            }
        }

        if isLoadingChanged {
            SELogger.debug(.events, "Is loading \(newPlaybackInfo.isLoading)")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeIsLoading: newPlaybackInfo.isLoading) }
            }
        }

        if playbackStateChanged {
            SELogger.info(.events, "Playback state \(previousPlaybackInfo.state) → \(newPlaybackInfo.state)")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangePlaybackState: newPlaybackInfo.state) }
            }
        }

        if playWhenReadyChanged || previousPlaybackInfo.playWhenReadyChangeReason != newPlaybackInfo.playWhenReadyChangeReason {
            SELogger.info(.events, "Play when ready \(newPlaybackInfo.playWhenReady), reason \(newPlaybackInfo.playWhenReadyChangeReason)")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didChangePlayWhenReady: newPlaybackInfo.playWhenReady, reason: newPlaybackInfo.playWhenReadyChangeReason)
                }
            }
        }

        if previousPlaybackInfo.playbackSuppressionReason != newPlaybackInfo.playbackSuppressionReason {
            SELogger.info(.events, "Playback suppression \(newPlaybackInfo.playbackSuppressionReason)")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates {
                    $0.player(self, didChangePlaybackSuppressionReason: newPlaybackInfo.playbackSuppressionReason)
                }
            }
        }

        if previousPlaybackInfo.isPlaying != newPlaybackInfo.isPlaying {
            SELogger.info(.events, "Is playing \(newPlaybackInfo.isPlaying)")
            DispatchQueue.main.async { [self] in
                delegate.invokeDelegates { $0.player(self, didChangeIsPlaying: newPlaybackInfo.isPlaying) }
            }
        }

        if previousPlaybackInfo.playbackParameters != newPlaybackInfo.playbackParameters {
            SELogger.info(.events, "Playback rate \(newPlaybackInfo.playbackParameters.playbackRate)")
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
        var oldWindowId: AnyHashable?
        var oldPeriodId: AnyHashable?
        var oldMediaItemIndex = oldMaskingMediaItemIndex
        var oldPeriodIndex = oldMaskingMediaItemIndex
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
        var newWindowId: AnyHashable?
        var newPeriodId: AnyHashable?
        let newMediaItemIndex = currentMediaItemIndex
        var newPeriodIndex = currentPeriodIndex
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
        let oldTimeline = oldPlaybackInfo.timeline
        let newTimeline = playbackInfo.timeline

        if oldTimeline.isEmpty, newTimeline.isEmpty {
            return (false, nil)
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
        var startWindowIndex = startWindowIndex
        var startPosition = startPosition
        let currentWindowIndex = currentWindowIndexInternal(playbackInfo: playbackInfo)
        let currentPosition = currentPosition
        pendingOperationAcks += 1
        if !mediaSourceHolderSnapshots.isEmpty {
            removeMediaSourceHolders(range: 0 ..< mediaSourceHolderSnapshots.count)
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
        let currentIndex = currentWindowIndexInternal(playbackInfo: playbackInfo) ?? .zero
        let contentPosition = contentPositionInternal(playbackInfo: playbackInfo)
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
        PlaylistTimeline(
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
        }

        if playingPeriodChanged || newContentPosition < oldContentPosition {
            // TODO: assert(!newPeriodId.isAd)
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
            let maskedTotalBufferedDuration = max(
                .zero,
                totalBufferedDurationInternal(playbackInfo: playbackInfo) - (newContentPosition - oldContentPosition)
            )
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
        ) else {
            return nil
        }

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

    /// The position in the media item of a time of the playing period.
    private func windowPosition(ofPeriodTime periodTime: CMTime) -> CMTime {
        guard periodTime.isNumeric, !playbackInfo.timeline.isEmpty,
              playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId) != nil else {
            return periodTime
        }
        return windowPosition(ofPeriodPosition: periodTime, timeline: playbackInfo.timeline, periodId: playbackInfo.periodId)
    }

    private func windowPosition(ofPeriodPosition periodPosition: CMTime, timeline: Timeline, periodId: MediaPeriodId) -> CMTime {
        timeline.periodById(periodId.periodId, period: period)
        return periodPosition + period.positionInWindow
    }

    private func createMessageInternal(handler: @escaping (_ messageType: Int, _ message: Any?) async -> Void) -> PlayerMessage {
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
        let playbackSuppressionReason = computePlaybackSuppressionReason(playWhenReady: playWhenReady)
        guard playbackInfo.playWhenReady != playWhenReady ||
            playbackInfo.playbackSuppressionReason != playbackSuppressionReason ||
            playbackInfo.playWhenReadyChangeReason != changeReason else {
            return
        }

        pendingOperationAcks += 1

        let time = timebase.time
        var newPlaybackInfo = playbackInfo
            .playWhenReady(
                playWhenReady,
                playWhenReadyChangeReason: changeReason,
                playbackSuppressionReason: playbackSuppressionReason
            )
            .setPosition(time)
        // The buffer ahead shrinks with the position that moves here, by the same time.
        let played = max(.zero, time - playbackInfo.position)
        newPlaybackInfo.totalBufferedDuration = max(.zero, playbackInfo.totalBufferedDuration - played)

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
        playWhenReady && audioSessionCommand == .wait ? .audioSessionLoss : .none
    }

    // MARK: - Audio session

    /// Tells the audio session controller how the player uses the session now.
    private func reportAudioSessionUsage() {
        let state = playbackInfo.state
        let usage = AudioSessionUsage(
            policy: _audioSessionPolicy,
            hasMedia: state != .idle,
            wantsToPlay: playbackInfo.playWhenReady && (state == .buffering || state == .ready),
            isInaudible: internalPlayer.isMuted || internalPlayer.volume == 0
        )
        guard usage != reportedAudioSessionUsage else { return }
        reportedAudioSessionUsage = usage
        audioSessionController.report(usage, id: identifier)
    }

    private func handleAudioSessionCommand(_ command: AudioSessionCommand) {
        SELogger.info(.audioSession, "Player \(identifier.uuidString.prefix(8)): \(command)")
        switch command {
        case .play,
             .wait:
            audioSessionCommand = command
            updatePlayWhenReady(playbackInfo.playWhenReady, changeReason: playbackInfo.playWhenReadyChangeReason)
        case let .pause(reason):
            audioSessionCommand = .play
            updatePlayWhenReady(false, changeReason: reason)
        }
    }

    private func canUpdateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) -> Bool {
        guard range.count == mediaItems.count else { return false }

        for (offset, index) in range.enumerated() {
            if !mediaSourceHolderSnapshots[index].mediaSource.canUpdateMediaItem(new: mediaItems[offset]) {
                return false
            }
        }

        return true
    }

    private func updateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) {
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
    var currentTracks: Tracks {
        lock.withLock { playbackInfo.trackSelectorResult.tracks }
    }

    var trackSelectionParameters: TrackSelectionParameters {
        get { trackSelector.getParameters() }
        set { setTrackSelectionParameters(newValue, application: .deferred) }
    }

    func setTrackSelectionParameters(_ parameters: TrackSelectionParameters, application: TrackSelectionApplication) {
        guard !parameters.isEqual(to: trackSelector.getParameters()) else {
            return
        }
        trackSelector.setParameters(parameters, application: application)
        let parameters = trackSelector.getParameters()
        DispatchQueue.main.async { [self] in
            delegate.invokeDelegates {
                $0.player(self, didChangeTrackSelectionParameters: parameters)
            }
        }
    }

    func setVideoOutput(_ output: any VideoOutput) {
        internalPlayer.setVideoOutput(output)
    }

    func removeVideoOutput(_ output: any VideoOutput) {
        setVideoOutputSize(nil, for: output)
        internalPlayer.removeVideoOutput(output)
    }

    func setVideoOutputSize(_ size: CGSize?, for output: AnyObject) {
        let largest = videoOutputSizesLock.withLock {
            videoOutputSizes[ObjectIdentifier(output)] = size
            return videoOutputSizes.values.max { $0.width * $0.height < $1.width * $1.height }
        }
        trackSelector.setVideoOutputSize(largest)
    }

    /// Reports the position in the media item, as ``currentPosition`` does: the timebase runs on the time of the
    /// playing period, which a live window moves along.
    func addPeriodicTimeObserver(for interval: CMTime, queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject {
        try self.lock.withLock {
            let observer = try PeriodicTimebaseObserver(
                timebase: timebase,
                interval: interval,
                queue: queue,
                block: { [weak self] periodTime in
                    guard let self else { return }
                    block(self.lock.withLock { self.windowPosition(ofPeriodTime: periodTime) })
                }
            )
            timeObservers.insert(observer)
            return observer
        }
    }

    /// Takes and reports positions in the media item. A live window moves along its period: the times are placed on
    /// the period as the window is when the observer is added.
    func addBoundaryTimeObserver(for times: [CMTime], queue: DispatchQueue, block: @escaping (CMTime) -> Void) throws -> AnyObject {
        try self.lock.withLock {
            let windowOffset = windowPosition(ofPeriodTime: .zero)
            let observer = try BoundaryTimebaseObserver(
                timebase: timebase,
                times: times.map { $0 - windowOffset },
                queue: queue,
                block: { [weak self] periodTime in
                    guard let self else { return }
                    block(self.lock.withLock { self.windowPosition(ofPeriodTime: periodTime) })
                }
            )
            timeObservers.insert(observer)
            return observer
        }
    }

    func removeTimeObserver(_ observer: AnyObject) {
        guard let observer = observer as? TimebaseTimeObserver else { return }
        // At once: on the queue of its block, the block is not called again.
        observer.invalidate()
        lock.withLock { _ = self.timeObservers.remove(observer) }
    }
}

extension SEPlayerImpl: SEPlayerImplInternalDelegate {
    func onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate) {
        lock.withLock { self._onPlaybackInfoUpdate(playbackInfoUpdate: playbackInfoUpdate) }
    }

    func _onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate) {
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
                        windowPosition(
                            ofPeriodPosition: playbackInfoUpdate.playbackInfo.discontinuityStartPosition,
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

private extension SEPlayerImpl {
    /// Receives what the renderers output for the player, which keeps it and tells its delegates.
    final class ComponentListener: TextOutput, MetadataOutput, VideoRendererEventListener, AudioRendererEventListener {
        weak var player: SEPlayerImpl?

        func onMetadata(_ metadata: Metadata) {
            player?.addDynamicMetadata(metadata)
        }

        func onCues(_ cueGroup: CueGroup) {
            MainActor.assumeIsolated {
                guard let player else { return }
                player.currentCues = cueGroup
                player.delegate.invokeDelegates { $0.player(player, didChangeCues: cueGroup) }
            }
        }

        func onVideoSizeChanged(_ videoSize: VideoSize) {
            guard let player else { return }
            player.lock.withLock {
                guard player._videoSize != videoSize else { return }
                SELogger.info(.events, "Video size \(videoSize.width)×\(videoSize.height)")
                player._videoSize = videoSize
                DispatchQueue.main.async {
                    player.delegate.invokeDelegates { $0.player(player, didChangeVideoSize: videoSize) }
                }
            }
        }

        func onVideoInputFormatChanged(_ format: AnyFormat?) {
            guard let player else { return }
            player.lock.withLock { player._videoFormat = format }
        }

        func onAudioInputFormatChanged(_ format: AnyFormat?) {
            guard let player else { return }
            player.lock.withLock { player._audioFormat = format }
        }

        func onRenderedFirstFrame() {
            guard let player else { return }
            SELogger.info(.events, "First frame rendered")
            DispatchQueue.main.async {
                player.delegate.invokeDelegates { $0.playerDidRenderFirstFrame(player) }
            }
        }
    }
}

extension SEPlayerImpl: AudioSessionClient {
    func audioSessionController(_ controller: AudioSessionController, didSend command: AudioSessionCommand) {
        lock.withLock { self.handleAudioSessionCommand(command) }
    }
}
