//
//  SEPlayerImplInternal.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMSync

protocol SEPlayerImplInternalDelegate: AnyObject {
    func onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate)
}

final class SEPlayerImplInternal: @unchecked Sendable, Handler.Callback, MediaSourceList.Delegate, MediaPeriodCallback, PlayerMessage.Sender, TrackSelector.InvalidationListener {
    weak var playbackInfoUpdateListener: SEPlayerImplInternalDelegate?

    let identifier: UUID

    var volume: Float {
        get { _volume }
        set {
            _volume = volume
            // TODO: add ability to change volume renderers.forEach { $0.volume = newValue }
        }
    }

    var isMuted: Bool {
        get { _isMuted }
        set {
            if _isMuted != newValue {
                // TODO: renderers.forEach { $0.volume = newValue ? .zero : _volume }
            }

            _isMuted = newValue

            audioSessionManager.setPrefferedStrategy(
                strategy: newValue ? .mixWithOthers : .playback,
                for: identifier
            )

        }
    }

    let queue: Queue
    let playerActor: PlayerActor
    private let handler: HandlerWrapper
    private let renderers: [RenderersHolder]
    private let rendererCapabilities: [RendererCapabilitiesResolver]
    private var rendererReportedReady: [Bool]
    private let trackSelector: TrackSelector
    private let emptyTrackSelectorResult: TrackSelectorResult
    private let loadControl: LoadControl
    private let bandwidthMeter: BandwidthMeter
    private var window: Window
    private var period: Period
    private let backBufferDurationUs: Int64
    private let retainBackBufferFromKeyframe: Bool
    private let mediaClock: DefaultMediaClock
    private let clock: SEClock
    private let periodQueue: MediaPeriodQueue
    private let mediaSourceList: MediaSourceList
    private let audioSessionManager: IAudioSessionManager
    private let hasSecondaryRenderers: Bool

    private var pendingMessages = [PendingMessageInfo]()
    private var _volume: Float = 1.0
    private var _isMuted: Bool = false
    private var seekParameters: SeekParameters
    private var playbackInfo: PlaybackInfo
    private var playbackInfoUpdate: PlaybackInfoUpdate
    private var released: Bool = false
    private var pauseAtEndOfWindow: Bool
    private var pendingPauseAtEndOfPeriod: Bool = false
    private var isRebuffering: Bool = false
    private var lastRebufferRealtimeMs: Int64
    private var shouldContinueLoading: Bool = false
    private var repeatMode: RepeatMode
    private var shuffleModeEnabled: Bool
    private var enabledRendererCount: Int = 0
    private var pendingInitialSeekPosition: SeekPosition?
    private var rendererPositionUs: Int64 = .zero
    private var rendererPositionElapsedRealtimeUs: Int64 = .zero
    private var nextPendingMessageIndexHint = 0
    private var deliverPendingMessageAtStartPositionRequired = true
    private var pendingRecoverableRendererError: Error?
    private var playbackMaybeBecameStuckAtMs: Int64
    private var preloadConfiguration: PreloadConfiguration
    private var lastPreloadPoolInvalidationTimeline: Timeline
    private var prewarmingMediaPeriodDiscontinuity = Int64.timeUnset
    private var isPrewarmingDisabledUntilNextTransition: Bool = false
    private var timerIsSuspended: Bool = false
    private var ignoreAudioSinkFlushError = false

    init(
        queue: Queue,
        renderers: [SERenderer],
        trackSelector: TrackSelector,
        emptyTrackSelectorResult: TrackSelectorResult,
        loadControl: LoadControl,
        bandwidthMeter: BandwidthMeter,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        seekParameters: SeekParameters,
        pauseAtEndOfWindow: Bool,
        clock: SEClock,
        mediaClock: DefaultMediaClock,
        identifier: UUID,
        preloadConfiguration: PreloadConfiguration,
        audioSessionManager: IAudioSessionManager
    ) throws {
        self.queue = queue
        self.playerActor = queue.playerActor()
        self.handler = clock.createHandler(queue: queue, looper: nil)
        self.identifier = identifier
        self.trackSelector = trackSelector
        self.emptyTrackSelectorResult = emptyTrackSelectorResult
        self.loadControl = loadControl
        self.bandwidthMeter = bandwidthMeter
        self.repeatMode = repeatMode
        self.shuffleModeEnabled = shuffleModeEnabled
        self.seekParameters = seekParameters
        self.pauseAtEndOfWindow = pauseAtEndOfWindow
        self.clock = clock
        self.mediaClock = mediaClock
        self.preloadConfiguration = preloadConfiguration
        self.audioSessionManager = audioSessionManager

        playbackMaybeBecameStuckAtMs = .timeUnset
        lastRebufferRealtimeMs = .timeUnset
        backBufferDurationUs = loadControl.getBackBufferDurationUs(playerId: identifier)
        retainBackBufferFromKeyframe = loadControl.retainBackBufferFromKeyframe(playerId: identifier)
        lastPreloadPoolInvalidationTimeline = emptyTimeline

        playbackInfo = PlaybackInfo.dummy(clock: clock, emptyTrackSelectorResult: emptyTrackSelectorResult)
        playbackInfoUpdate = PlaybackInfoUpdate(playbackInfo: playbackInfo)
        self.renderers = renderers.enumerated().map { RenderersHolder(primaryRenderer: $1, index: $0) }
        rendererCapabilities = renderers.map { $0.getCapabilities() }
        rendererCapabilities.forEach {
            $0.listener = trackSelector.getRendererCapabilitiesListener()
        }
        rendererReportedReady = Array(repeating: false, count: renderers.count)
        hasSecondaryRenderers = false

        window = Window()
        period = Period()

        let mediaSourceList = MediaSourceList(playerId: identifier)
        self.mediaSourceList = mediaSourceList
        periodQueue = MediaPeriodQueue(mediaPeriodBuilder: { info, rendererPositionOffsetUs in
            try! MediaPeriodHolder(
                queue: queue,
                rendererCapabilities: renderers.map { $0.getCapabilities() },
                rendererPositionOffsetUs: rendererPositionOffsetUs,
                trackSelector: trackSelector,
                allocator: loadControl.getAllocator(),
                mediaSourceList: mediaSourceList,
                info: info,
                emptyTrackSelectorResult: emptyTrackSelectorResult,
                targetPreloadBufferDurationUs: preloadConfiguration.targetPreloadDurationUs
            )
        })

        mediaSourceList.delegate = self
        handler.callback = self
        trackSelector.initialize(listener: self, bandwidthMeter: bandwidthMeter)
//        NotificationCenter.default
//            .addObserver(self, selector: #selector(didGoBS), name: UIApplication.didEnterBackgroundNotification, object: nil)
//        NotificationCenter.default
//            .addObserver(self, selector: #selector(didgoFromBg), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    nonisolated func prepare() {
        handler.obtainMessage(what: SEPlayerMessageImpl.prepare).sendToTarget()
    }

    nonisolated func setPlayWhenReady(
        _ playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) {
        handler.obtainMessage(what: SEPlayerMessageImpl.playWhenReady(
            playWhenReady,
            playWhenReadyChangeReason,
            playbackSuppressionReason
        )).sendToTarget()
    }

    nonisolated func setPauseAtEndOfWindow(_ pauseAtEndOfWindow: Bool) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setPauseAtEndOfWindow(pauseAtEndOfWindow))
            .sendToTarget()
    }

    nonisolated func setRepeatMode(_ repeatMode: RepeatMode) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setRepeatMode(repeatMode)).sendToTarget()
    }

    nonisolated func setShuffleModeEnabled(_ shuffleModeEnabled: Bool) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setShuffleEnabled(shuffleModeEnabled)).sendToTarget()
    }

    nonisolated func setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setPreloadConfiguration(preloadConfiguration)).sendToTarget()
    }

    nonisolated func seekTo(timeline: Timeline, windowIndex: Int, positionUs: Int64) {
        handler.obtainMessage(what: SEPlayerMessageImpl.seekTo(
            timeline, windowIndex, positionUs
        )).sendToTarget()
    }

    nonisolated func setPlaybackParameters(_ playbackParameters: PlaybackParameters) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setPlaybackParameters(playbackParameters)).sendToTarget()
    }

    nonisolated func setSeekParameters(_ seekParameters: SeekParameters) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setSeekParameters(seekParameters)).sendToTarget()
    }

    nonisolated func stop() { handler.obtainMessage(what: SEPlayerMessageImpl.stop).sendToTarget() }

    nonisolated func setMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        windowIndex: Int?,
        positionUs: Int64,
        shuffleOrder: ShuffleOrder
    ) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setMediaSources(
            mediaSources,
            windowIndex,
            positionUs,
            shuffleOrder
        )).sendToTarget()
    }

    nonisolated func insertMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        at index: Int,
        shuffleOrder: ShuffleOrder
    ) {
        handler.obtainMessage(what: SEPlayerMessageImpl.addMediaSources(
            mediaSources, index, shuffleOrder
        )).sendToTarget()
    }

    nonisolated func removeMediaSources(range: Range<Int>, shuffleOrder: ShuffleOrder) {
        handler.obtainMessage(what: SEPlayerMessageImpl.removeMediaSources(range, shuffleOrder)).sendToTarget()
    }

    nonisolated func moveMediaSources(range: Range<Int>, to newIndex: Int, shuffleOrder: ShuffleOrder) {
        handler.obtainMessage(what: SEPlayerMessageImpl.moveMediaSources(range, newIndex, shuffleOrder)).sendToTarget()
    }

    nonisolated func setShuffleOrder(_ shuffleOrder: ShuffleOrder) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setShuffleOrder(shuffleOrder)).sendToTarget()
    }

    nonisolated func updateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) {
        handler.obtainMessage(what: SEPlayerMessageImpl.updateMediaSourcesWithMediaItems(
            mediaItems, range
        )).sendToTarget()
    }

    nonisolated func sendMessage(_ message: PlayerMessage) {
        // TODO: check for release
        handler.obtainMessage(what: SEPlayerMessageImpl.sendMessage(message)).sendToTarget()
    }

    nonisolated func release() async {
        await withCheckedContinuation { continuation in
            handler.obtainMessage(what: SEPlayerMessageImpl.release(continuation)).sendToTarget()
        }
    }

    func playlistUpdateRequested() {
        handler.removeMessages(SEPlayerMessageImpl.doSomeWork)
        handler.sendEmptyMessage(SEPlayerMessageImpl.playlistUpdateRequested)
    }

    func didPrepare(mediaPeriod: any MediaPeriod) {
        handler.obtainMessage(what: SEPlayerMessageImpl.periodPrepared(mediaPeriod)).sendToTarget()
    }

    func continueLoadingRequested(with source: any MediaPeriod) {
        handler.obtainMessage(what: SEPlayerMessageImpl.sourceContinueLoadingRequested(source)).sendToTarget()
    }

    func onTrackSelectionsInvalidated() {
        handler.sendEmptyMessage(SEPlayerMessageImpl.trackSelectionInvalidated)
    }

    func onRendererCapabilitiesChanged(_ renderer: SERenderer) {
        handler.sendEmptyMessage(SEPlayerMessageImpl.rendererCapabilitiesChanged)
    }

    func handleMessage(_ msg: Message) -> Bool {
        do {
            switch msg.what as! SEPlayerMessageImpl {
            case .prepare:
                try prepareInternal()
            case let .playWhenReady(playWhenReady, playWhenReadyChangeReason, playbackSuppressionReason):
                try setPlayWhenReadyInternal(
                    playWhenReady,
                    playbackSuppressionReason: playbackSuppressionReason,
                    operationAck: true,
                    playWhenReadyChangeReason: playWhenReadyChangeReason
                )
            case let .setRepeatMode(repeatMode):
                try setRepeatModeInternal(repeatMode)
            case let .setShuffleEnabled(shuffleModeEnabled):
                try setShuffleModeEnabledInternal(shuffleModeEnabled)
            case let .setPreloadConfiguration(preloadConfiguration):
                try setPreloadConfigurationInternal(preloadConfiguration)
            case .doSomeWork:
                try doSomeWork()
            case let .seekTo(timeline, windowIndex, positionUs):
                try seekToInternal(
                    seekPosition: .init(
                        timeline: timeline,
                        windowIndex: windowIndex,
                        windowPositionUs: positionUs
                    ),
                    incrementAcks: true
                )
            case let .setPlaybackParameters(playbackParameters):
                setPlaybackParametersInternal(playbackParameters)
            case let .setSeekParameters(seekParameters):
                setSeekParametersInternal(seekParameters)
            case let .setVideoOutput(output):
                try setVideoOutputInternal(output)
            case let .removeVideoOutput(output):
                try removeVideoOutputInternal(output)
            case .stop:
                stopInternal(forceResetRenderers: false, acknowledgeStop: true)
            case let .periodPrepared(mediaPeriod):
                try handlePeriodPrepared(mediaPeriod: mediaPeriod)
            case let .sourceContinueLoadingRequested(mediaPeriod):
                handleContinueLoadingRequested(mediaPeriod: mediaPeriod)
            case .trackSelectionInvalidated:
                try reselectTracksInternal()
            case let .playbackParametersChangedInternal(parameters):
                try handlePlaybackParameters(playbackParameters: parameters, acknowledgeCommand: false)
            case let .sendMessage(message):
                try sendMessageInternal(message)
            case let .sendMessageToTargetQueue(message):
                try sendMessageToTargetQueue(message)
            case let .setMediaSources(mediaSources, windowIndex, positionUs, shuffleOrder):
                try setMediaSourcesInternal(
                    mediaSources,
                    windowIndex: windowIndex,
                    positionUs: positionUs,
                    shuffleOrder: shuffleOrder
                )
            case let .addMediaSources(mediaSources, index, shufflerOrder):
                try insertMediaSourcesInternal(mediaSources, at: index, shuffleOrder: shufflerOrder)
            case let .moveMediaSources(range, index, shufflerOrder):
                moveMediaSourcesInternal(range: range, to: index, shuffleOrder: shufflerOrder)
            case let .removeMediaSources(range, shufflerOrder):
                removeMediaSourcesInternal(range: range, shuffleOrder: shufflerOrder)
            case let .setShuffleOrder(shufflerOrder):
                setShuffleOrderInternal(shufflerOrder)
            case .playlistUpdateRequested:
                try mediaSourceListUpdateRequestedInternal()
            case let .setPauseAtEndOfWindow(pauseAtEndOfWindow):
                try setPauseAtEndOfWindowInternal(pauseAtEndOfWindow)
            case .attemptRendererErrorRecovery:
                try attemptRendererErrorRecovery()
            case .rendererCapabilitiesChanged:
                try reselectTracksInternalAndSeek()
            case let .updateMediaSourcesWithMediaItems(mediaItems, range):
                try updateMediaSourcesInternal(with: mediaItems, range: range)
            case let .release(continuation):
                releaseInternal(continuation: continuation)
                return true
            case .noMessage:
                return false
            }
        } catch {
            print("❌❌❌❌ ERROR")
            print(error)
//            handler.sendMessageAtFrontOfQueue(
//                handler.obtainMessage(
//                    what: SEPlayerMessageImpl.attemptRendererErrorRecovery
//                )
//            )
//            fatalError("\(error)")
            stopInternal(forceResetRenderers: true, acknowledgeStop: false)
            playbackInfo = playbackInfo.setPlaybackError(error)
        }

        maybeNotifyPlaybackInfoChanged()
        return true
    }

    private func setState(_ state: PlayerState) {
        assert(queue.isCurrent())
        guard playbackInfo.state != state else { return }
        if state != .buffering {
            playbackMaybeBecameStuckAtMs = .timeUnset
        }
        print("🫟 SET STATE = \(state)")
        playbackInfo = playbackInfo.playbackState(state)
    }

    private func maybeNotifyPlaybackInfoChanged() {
        assert(queue.isCurrent())
        playbackInfoUpdate.setPlaybackInfo(playbackInfo)
        if playbackInfoUpdate.hasPendingChange {
            let playbackInfoUpdateCopy = playbackInfoUpdate
            playbackInfoUpdateListener?.onPlaybackInfoUpdate(playbackInfoUpdate: playbackInfoUpdateCopy)
            playbackInfoUpdate = PlaybackInfoUpdate(playbackInfo: playbackInfo)
        }
    }

    private func prepareInternal() throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        audioSessionManager.registerPlayer(self, playerId: identifier, playerIsolation: queue.playerActor())
        resetInternal(
            resetRenderers: false,
            resetPosition: false,
            releaseMediaSourceList: false,
            resetError: true
        )
        loadControl.onPrepared(playerId: identifier)
        setState(playbackInfo.timeline.isEmpty ? .ended : .buffering)
        try! mediaSourceList.prepare(mediaTransferListener: bandwidthMeter.transferListener)
        try renderers.forEach { try $0.setControlTimebase(mediaClock.getTimebase()) }
        handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
    }

    private func setMediaSourcesInternal(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        windowIndex: Int?,
        positionUs: Int64,
        shuffleOrder: ShuffleOrder
    ) throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        if let windowIndex {
            pendingInitialSeekPosition = SeekPosition(
                timeline: PlaylistTimeline(mediaSourceInfoHolders: mediaSources, shuffleOrder: shuffleOrder),
                windowIndex: windowIndex,
                windowPositionUs: positionUs
            )
        }
        let timeline = try mediaSourceList.setMediaSource(holders: mediaSources, shuffleOrder: shuffleOrder)
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func insertMediaSourcesInternal(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        at index: Int,
        shuffleOrder: ShuffleOrder
    ) throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        let timeline = try mediaSourceList.addMediaSource(
            index: index,
            holders: mediaSources,
            shuffleOrder: shuffleOrder
        )
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func moveMediaSourcesInternal(range: Range<Int>, to newIndex: Int, shuffleOrder: ShuffleOrder) {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        let timeline = mediaSourceList.moveMediaSourceRange(range: range, to: newIndex, shuffleOrder: shuffleOrder)
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func removeMediaSourcesInternal(range: Range<Int>, shuffleOrder: ShuffleOrder) {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        let timeline = mediaSourceList.removeMediaSource(range: range, shuffleOrder: shuffleOrder)
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func mediaSourceListUpdateRequestedInternal() throws {
        handleMediaSourceListInfoRefreshed(
            timeline: mediaSourceList.createTimeline(),
            isSourceRefresh: true
        )
    }

    private func setShuffleOrderInternal(_ shuffleOrder: ShuffleOrder) {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        let timeline = mediaSourceList.setShuffleOrder(new: shuffleOrder)
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func updateMediaSourcesInternal(with mediaItems: [MediaItem], range: Range<Int>) throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        let timeline = try mediaSourceList.updateMediaSources(with: mediaItems, range: range)
        handleMediaSourceListInfoRefreshed(timeline: timeline, isSourceRefresh: false)
    }

    private func notifyTrackSelectionPlayWhenReadyChanged(_ playWhenReady: Bool) {
        var periodHolder = periodQueue.playing
        while let unwrappedPeriodHolder = periodHolder {
            unwrappedPeriodHolder.trackSelectorResults.selections.forEach {
                $0?.playWhenReadyChanged(playWhenReady)
            }
            periodHolder = unwrappedPeriodHolder.next
        }
    }

    private func setPlayWhenReadyInternal(
        _ playWhenReady: Bool,
        playbackSuppressionReason: PlaybackSuppressionReason,
        operationAck: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
    ) throws {
        print("🫟 setPlayWhenReadyInternal, time = \(clock.microseconds)")
        playbackInfoUpdate.incrementPendingOperationAcks(operationAck ? 1 : 0)
        try updatePlayWhenReadyWithAudioFocus(
            playWhenReady,
            playbackSuppressionReason: playbackSuppressionReason,
            playWhenReadyChangeReason: playWhenReadyChangeReason
        )
    }

    private func setPlayWhenReadyInternalWithAudioFocus() {
//        assert(queue.isCurrent())
//        do {
//            try! setPlayWhenReadyInternal(
//                false,
//                reason: .routeChanged,
//                playbackSuppressionReason: .audioSessionLoss,
//                operationAck: false
//            )
//
//            queue.justDispatch {
//                try! self.setPlayWhenReadyInternal(
//                    true,
//                    reason: .routeChanged,
//                    playbackSuppressionReason: .none,
//                    operationAck: false
//                )
//            }
//
//            maybeNotifyPlaybackInfoChanged()
//        } catch {
//            handleError(error: error)
//        }
    }

    private func updatePlayWhenReadyWithAudioFocus() throws {
        try updatePlayWhenReadyWithAudioFocus(
            playbackInfo.playWhenReady,
            playbackSuppressionReason: playbackInfo.playbackSuppressionReason,
            playWhenReadyChangeReason: playbackInfo.playWhenReadyChangeReason
        )
    }

    private func updatePlayWhenReadyWithAudioFocus(
        _ playWhenReady: Bool,
        playbackSuppressionReason: PlaybackSuppressionReason,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason
    ) throws {
        // TODO: make call to audioSession
        try updatePlayWhenReadyWithAudioFocus(
            playWhenReady,
            playerCommand: .playWhenReady,
            reason: playWhenReadyChangeReason,
            playbackSuppressionReason: playbackSuppressionReason
        )
    }

    private func updatePlayWhenReadyWithAudioFocus(
        _ playWhenReady: Bool,
        playerCommand: PlayerCommand,
        reason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) throws {
        print("🫟 updatePlayWhenReadyWithAudioFocus, time = \(clock.microseconds)")
        let playWhenReady = playWhenReady && playerCommand != .doNotPlay
        let playWhenReadyChangeReason = updatePlayWhenReadyChangeReason(playerCommand: playerCommand, playWhenReadyChangeReason: reason)
        let playbackSuppressionReason = updatePlaybackSuppressionReason(playerCommand: playerCommand, playbackSuppressionReason: playbackSuppressionReason)

        guard playbackInfo.playWhenReady != playWhenReady ||
              playbackInfo.playbackSuppressionReason != playbackSuppressionReason ||
              playbackInfo.playWhenReadyChangeReason != playWhenReadyChangeReason else {
            return
        }

        playbackInfo = playbackInfo.playWhenReady(
            playWhenReady,
            playWhenReadyChangeReason: playWhenReadyChangeReason,
            playbackSuppressionReason: playbackSuppressionReason
        )

        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtimeMs: false)
        notifyTrackSelectionPlayWhenReadyChanged(playWhenReady)
        if !shouldPlayWhenReady() {
            stopRenderers()
            try! updatePlaybackPositions()
            periodQueue.reevaluateBuffer(rendererPositionUs: rendererPositionUs)
        } else {
            if playbackInfo.state == .ready {
//                try renderers.forEach { try $0.setControlTimebase(mediaClock.getTimebase()) }
                mediaClock.start()
                try! startRenderers()
                handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
            } else if playbackInfo.state == .buffering {
                handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
            }
        }
    }

    private func setPauseAtEndOfWindowInternal(_ pauseAtEndOfWindow: Bool) throws {
        assert(queue.isCurrent())
        self.pauseAtEndOfWindow = pauseAtEndOfWindow
        resetPendingPauseAtEndOfPeriod()
        if pendingPauseAtEndOfPeriod, periodQueue.reading != periodQueue.playing {
            // When pausing is required, we need to set the streams of the playing period final. If we
            // already started reading the next period, we need to flush the renderers.
            try seekToCurrentPosition(sendDiscontinuity: true)
            handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
        }
    }

    private func setRepeatModeInternal(_ repeatMode: RepeatMode) throws {
        assert(queue.isCurrent())
        let result = periodQueue.updateRepeatMode(new: repeatMode, timeline: playbackInfo.timeline)
        if result.contains(.alteredReadingPeriod) {
            try! seekToCurrentPosition(sendDiscontinuity: true)
        } else if result.contains(.alteredPrewarmingPeriod) {
            disableAndResetPrewarmingRenderers()
        }
        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
    }

    private func setShuffleModeEnabledInternal(_ shuffleModeEnabled: Bool) throws {
        assert(queue.isCurrent())
        let result = periodQueue.updateShuffleMode(new: shuffleModeEnabled, timeline: playbackInfo.timeline)
        if result.contains(.alteredReadingPeriod) {
            try! seekToCurrentPosition(sendDiscontinuity: true)
        } else if result.contains(.alteredPrewarmingPeriod) {
            disableAndResetPrewarmingRenderers()
        }
        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
    }

    private func setPreloadConfigurationInternal(_ preloadConfiguration: PreloadConfiguration) throws {
        assert(queue.isCurrent())
        self.preloadConfiguration = preloadConfiguration
        try periodQueue.updatePreloadConfiguration(
            new: preloadConfiguration,
            timeline: playbackInfo.timeline
        )
    }

    private func seekToCurrentPosition(sendDiscontinuity: Bool) throws {
        guard let playingPeriod = periodQueue.playing else {
            return
        }

        let periodId = playingPeriod.info.id
        let newPositionUs = try! seekToPeriodPosition(
            periodId: periodId,
            periodPositionUs: playbackInfo.positionUs,
            forceDisableRenderers: true,
            forceBufferingState: false
        )

        if newPositionUs != playbackInfo.positionUs {
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: periodId,
                positionUs: newPositionUs,
                requestedContentPositionUs: playbackInfo.requestedContentPositionUs,
                discontinuityStartPositionUs: playbackInfo.discontinuityStartPositionUs,
                reportDiscontinuity: sendDiscontinuity,
                discontinuityReason: .internal
            )
        }
    }

    private func startRenderers() throws {
        print("🫟 startRenderers(), time = \(clock.microseconds)")
        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }
        let trackSelectorResult = playingPeriodHolder.trackSelectorResults
        for index in 0..<renderers.count {
            if !trackSelectorResult.isRendererEnabled(for: index) {
                continue
            }

            try! renderers[index].start()
        }
        print()
    }

    private func stopRenderers() {
        mediaClock.stop()
        renderers.forEach { $0.stop() }
        print()
    }

    private func attemptRendererErrorRecovery() throws {
        try reselectTracksInternalAndSeek()
    }

    private func updatePlaybackPositions() throws {
        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }

        let discontinuityPositionUs = playingPeriodHolder.isPrepared
            ? playingPeriodHolder.mediaPeriod.readDiscontinuity()
            : .timeUnset

        if discontinuityPositionUs != .timeUnset {
            if !playingPeriodHolder.isFullyBuffered() {
                periodQueue.removeAfter(mediaPeriodHolder: playingPeriodHolder)
                handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                maybeContinueLoading()
            }
            try! resetRendererPosition(periodPositionUs: discontinuityPositionUs)
            if discontinuityPositionUs != playbackInfo.positionUs {
                playbackInfo = handlePositionDiscontinuity(
                    mediaPeriodId: playbackInfo.periodId,
                    positionUs: discontinuityPositionUs,
                    requestedContentPositionUs: playbackInfo.requestedContentPositionUs,
                    discontinuityStartPositionUs: discontinuityPositionUs,
                    reportDiscontinuity: true,
                    discontinuityReason: .internal
                )
            }
        } else {
            rendererPositionUs = mediaClock
                .syncAndGetPosition(isReadingAhead: playingPeriodHolder !== periodQueue.reading)
            let periodPositionUs = playingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs)
            try maybeTriggerPendingMessages(oldPeriodPositionUs: playbackInfo.positionUs, newPeriodPositionUs: periodPositionUs)
            playbackInfo = playbackInfo.positionUs(periodPositionUs)
        }

        if let loading = periodQueue.loading {
            playbackInfo.bufferedPositionUs = loading.getBufferedPositionUs()
            playbackInfo.totalBufferedDurationUs = getTotalBufferedDurationUs()
        }

        // TODO: Adjust live playback speed to new position
    }

    private func setMediaClockPlaybackParameters(playbackParameters: PlaybackParameters) throws {
        handler.removeMessages(SEPlayerMessageImpl.playbackParametersChangedInternal(playbackParameters))
        mediaClock.setPlaybackParameters(new: playbackParameters)
    }

    private func notifyTrackSelectionRebuffer() {
        // TODO: notifyTrackSelectionRebuffer
    }

    private func doSomeWork() throws {
        assert(queue.isCurrent())
        let currentTime = DispatchTime.now()
        handler.removeMessages(SEPlayerMessageImpl.doSomeWork)

        try updatePeriods()

        if playbackInfo.state == .idle || playbackInfo.state == .ended {
            return
        }

        guard let playingPeriodHolder = periodQueue.playing else {
            scheduleNextWork(operationStartTime: currentTime)
            return
        }

        try updatePlaybackPositions()

        var renderersEnded = true
        var renderersAllowPlayback = true

        if playingPeriodHolder.isPrepared {
            rendererPositionElapsedRealtimeUs = clock.microseconds
            playingPeriodHolder.mediaPeriod.discardBuffer(
                to: playbackInfo.positionUs - backBufferDurationUs,
                toKeyframe: retainBackBufferFromKeyframe
            )

            for (index, renderer) in renderers.enumerated() {
                if renderer.enabledRendererCount == 0 {
                    maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: false)
                    continue
                }

                try renderer.render(
                    rendererPositionUs: rendererPositionUs,
                    rendererPositionElapsedRealtimeUs: rendererPositionElapsedRealtimeUs
                )
                renderersEnded = renderersEnded && renderer.isEnded
                let allowsPlayback = renderer.allowsPlayback(playingPeriodHolder: playingPeriodHolder)
                maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: allowsPlayback)
                renderersAllowPlayback = renderersAllowPlayback && allowsPlayback
                if !allowsPlayback {
                    try maybeThrowRendererStreamError()
                }
            }
        } else {
            try playingPeriodHolder.mediaPeriod.maybeThrowPrepareError()
        }

        let playingPeriodDurationUs = playingPeriodHolder.info.durationUs
        let finishedRendering = renderersEnded
            && playingPeriodHolder.isPrepared
            && (playingPeriodDurationUs == .timeUnset || playingPeriodDurationUs <= playbackInfo.positionUs)

        if finishedRendering, pendingPauseAtEndOfPeriod {
            pendingPauseAtEndOfPeriod = false
            try setPlayWhenReadyInternal(
                false,
                playbackSuppressionReason: playbackInfo.playbackSuppressionReason,
                operationAck: false,
                playWhenReadyChangeReason: .endOfMediaItem
            )
        }

        if finishedRendering, playingPeriodHolder.info.isFinal {
            print("🫟 ENDED")
            setState(.ended)
            stopRenderers()
        } else if playbackInfo.state == .buffering,
                  shouldTransitionToReadyState(renderersReadyOrEnded: renderersAllowPlayback) {
            print("🫟 READY")
            setState(.ready)
            pendingRecoverableRendererError = nil

            if shouldPlayWhenReady() {
                print("🫟 START PLAYBACK")
                updateRebufferingState(
                    isRebuffering: false,
                    resetLastRebufferRealtimeMs: false
                )
//                try renderers.forEach { try $0.setControlTimebase(mediaClock.getTimebase()) }
                mediaClock.start()
                try startRenderers()
            }
        } else if playbackInfo.state == .ready,
                  !(enabledRendererCount == 0 ? isTimelineReady() : renderersAllowPlayback) {
            print("🫟 BUFFERING STATE")
            updateRebufferingState(isRebuffering: shouldPlayWhenReady(), resetLastRebufferRealtimeMs: false)
            setState(.buffering)
            if isRebuffering {
                // TODO: notifyTrackSelectionRebuffer
                // TODO: livePlaybackSpeedControl.notifyRebuffer
            }
            stopRenderers()
        }

        var playbackMaybeStuck = false
        if playbackInfo.state == .buffering {
            for renderer in renderers {
                if renderer.isReading(from: playingPeriodHolder) {
                    try  maybeThrowRendererStreamError()
                }
            }

            if !playbackInfo.isLoading,
               playbackInfo.totalBufferedDurationUs < 500_000, // TODO: conts
               isLoadingPossible(mediaPeriodHolder: periodQueue.loading),
               shouldPlayWhenReady() {
                playbackMaybeStuck = true
            }
        }

        if !playbackMaybeStuck {
            playbackMaybeBecameStuckAtMs = .timeUnset
        } else if playbackMaybeBecameStuckAtMs == .timeUnset {
            playbackMaybeBecameStuckAtMs = clock.milliseconds
        } else if clock.milliseconds - playbackMaybeBecameStuckAtMs >= 4000 { // TODO: conts
            //                fatalError() // TODO: real error
            print("playbackMaybeStuck!!!")
        }

        let isPlaying = shouldPlayWhenReady() && playbackInfo.state == .ready
        if (isPlaying || playbackInfo.state == .buffering) || (playbackInfo.state == .ready && enabledRendererCount != 0) {
            scheduleNextWork(operationStartTime: currentTime)
        }
    }

    private func maybeTriggerOnRendererReadyChanged(rendererIndex: Int, allowsPlayback: Bool) {
        if rendererReportedReady[rendererIndex] != allowsPlayback {
            rendererReportedReady[rendererIndex] = allowsPlayback
            // TODO: analyticsCollector
        }
    }

    private func getCurrentLiveOffsetUs() {
        // TODO: make
    }

    private func getLiveOffsetUs() {
        // TODO: make
    }

    private func shouldUseLivePlaybackSpeedControl() {
        // TODO: make
    }

    private func scheduleNextWork(operationStartTime: DispatchTime) {
        let wakeUpTimeIntervalMs: Int = if playbackInfo.state == .ready, !shouldPlayWhenReady() {
            1000 // TODO: conts
        } else {
            Int(Time.usToMs(timeUs: 10_000)) // TODO: conts
        }

        handler.sendEmptyMessageAtTime(
            SEPlayerMessageImpl.doSomeWork,
            timeNs: operationStartTime.advanced(by: .milliseconds(wakeUpTimeIntervalMs))
        )
    }

    private func seekToInternal(seekPosition: SeekPosition, incrementAcks: Bool) throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(incrementAcks ? 1 : 0)
        print("🫟 seek positionUs = \(seekPosition.windowPositionUs), timeline = \(seekPosition.timeline), windowIndex = \(seekPosition.windowIndex)")

        let periodId: MediaPeriodId
        var periodPositionUs: Int64
        let requestedContentPositionUs: Int64
        var seekPositionAdjusted: Bool

        let resolvedSeekPosition = resolveSeekPositionUs(
            timeline: playbackInfo.timeline,
            seekPosition: seekPosition,
            trySubsequentPeriods: true,
            repeatMode: repeatMode,
            shuffleModeEnabled: shuffleModeEnabled,
            window: window,
            period: period
        )

        if let resolvedSeekPosition {
            let periodUUID = resolvedSeekPosition.periodId
            let resolvedContentPositionUs = resolvedSeekPosition.periodPositionUs
            requestedContentPositionUs = seekPosition.windowPositionUs == .timeUnset ? .timeUnset : resolvedContentPositionUs
            periodId = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
                timeline: playbackInfo.timeline,
                periodId: periodUUID,
                positionUs: resolvedContentPositionUs
            )
            periodPositionUs = resolvedContentPositionUs
            seekPositionAdjusted = seekPosition.windowPositionUs == .timeUnset
        } else {
            let firstPeriodAndPositionUs = placeholderFirstMediaPeriodPositionUs(timeline: playbackInfo.timeline)
            periodId = firstPeriodAndPositionUs.0
            periodPositionUs = firstPeriodAndPositionUs.1
            requestedContentPositionUs = .timeUnset
            seekPositionAdjusted = !playbackInfo.timeline.isEmpty
        }

        let finalBlock = { [self] in
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: periodId,
                positionUs: periodPositionUs,
                requestedContentPositionUs: requestedContentPositionUs,
                discontinuityStartPositionUs: periodPositionUs,
                reportDiscontinuity: seekPositionAdjusted,
                discontinuityReason: .seekAdjustment
            )
        }

        do {
            if playbackInfo.timeline.isEmpty {
                // Save seek position for later, as we are still waiting for a prepared source.
                pendingInitialSeekPosition = seekPosition
            } else if resolvedSeekPosition == nil {
                // End playback, as we didn't manage to find a valid seek position.
                if playbackInfo.state != .idle {
                    setState(.ended)
                }

                resetInternal(
                    resetRenderers: false,
                    resetPosition: true,
                    releaseMediaSourceList: false,
                    resetError: true
                )
            } else {
                // Execute the seek in the current media periods.
                var newPeriodPositionUs = periodPositionUs
                if periodId == playbackInfo.periodId {
                    if let playing = periodQueue.playing, playing.isPrepared, newPeriodPositionUs != 0 {
                        newPeriodPositionUs = playing.mediaPeriod.getAdjustedSeekPositionUs(
                            positionUs: newPeriodPositionUs,
                            seekParameters: seekParameters
                        )
                    }

                    if Time.usToMs(timeUs: newPeriodPositionUs) == Time.usToMs(timeUs: playbackInfo.positionUs),
                       playbackInfo.state == .buffering || playbackInfo.state == .ready {
                        periodPositionUs = playbackInfo.positionUs
                        
                        playbackInfo = handlePositionDiscontinuity(
                            mediaPeriodId: periodId,
                            positionUs: periodPositionUs,
                            requestedContentPositionUs: requestedContentPositionUs,
                            discontinuityStartPositionUs: periodPositionUs,
                            reportDiscontinuity: seekPositionAdjusted,
                            discontinuityReason: .seekAdjustment
                        )
                        
                        return
                    }
                }

                newPeriodPositionUs = try seekToPeriodPosition(
                    periodId: periodId,
                    periodPositionUs: newPeriodPositionUs,
                    forceBufferingState: playbackInfo.state == .ended
                )

                seekPositionAdjusted = seekPositionAdjusted || periodPositionUs != newPeriodPositionUs
                periodPositionUs = newPeriodPositionUs
                try updatePlaybackSpeedSettingsForNewPeriod(
                    newTimeline: playbackInfo.timeline,
                    newPeriodId: periodId,
                    oldTimeline: playbackInfo.timeline,
                    oldPeriodId: playbackInfo.periodId,
                    positionForTargetOffsetOverrideUs: requestedContentPositionUs,
                    forceSetTargetOffsetOverride: true
                )
            }
            finalBlock()
        } catch {
            finalBlock()
            throw error
        }
    }

    private func seekToPeriodPosition(
        periodId: MediaPeriodId,
        periodPositionUs: Int64,
        forceBufferingState: Bool,
    ) throws -> Int64 {
        try seekToPeriodPosition(
            periodId: periodId,
            periodPositionUs: periodPositionUs,
            forceDisableRenderers: periodQueue.playing !== periodQueue.reading,
            forceBufferingState: forceBufferingState,
        )
    }

    private func seekToPeriodPosition(
        periodId: MediaPeriodId,
        periodPositionUs: Int64,
        forceDisableRenderers: Bool,
        forceBufferingState: Bool
    ) throws -> Int64 {
        var periodPositionUs = periodPositionUs

        stopRenderers()
        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtimeMs: true)
        if forceBufferingState || playbackInfo.state == .ready {
            setState(.buffering)
        }

        let oldPlayingPeriodHolder = periodQueue.playing
        var newPlayingPeriodHolder = oldPlayingPeriodHolder

        while let unwrappedPeriod = newPlayingPeriodHolder {
            if periodId == unwrappedPeriod.info.id { break }
            newPlayingPeriodHolder = unwrappedPeriod.next
        }

        let newPlayingPeriodCheck = if let newPlayingPeriodHolder {
            newPlayingPeriodHolder.toRendererTime(periodTime: periodPositionUs) < 0
        } else {
            false
        }

        let shouldResetRenderers =
            forceDisableRenderers ||
            oldPlayingPeriodHolder !== newPlayingPeriodHolder || newPlayingPeriodCheck

        if shouldResetRenderers {
            try! disableRenderers()
            if let newPlayingPeriodHolder {
                while periodQueue.playing != newPlayingPeriodHolder {
                    periodQueue.advancePlayingPeriod()
                }
                periodQueue.removeAfter(mediaPeriodHolder: newPlayingPeriodHolder)
                newPlayingPeriodHolder.renderPositionOffset = MediaPeriodQueue.initialRendererPositionOffsetUs
                try! enableRenderers()
                newPlayingPeriodHolder.allRenderersInCorrectState = true
            }
        }

        disableAndResetPrewarmingRenderers()
        if let newPlayingPeriodHolder {
            periodQueue.removeAfter(mediaPeriodHolder: newPlayingPeriodHolder)

            if !newPlayingPeriodHolder.isPrepared {
                newPlayingPeriodHolder.info = newPlayingPeriodHolder.info.copyWithStartPositionUs(periodPositionUs)
            } else if newPlayingPeriodHolder.hasEnabledTracks {
                periodPositionUs = newPlayingPeriodHolder.mediaPeriod.seek(to: periodPositionUs)
                newPlayingPeriodHolder.mediaPeriod.discardBuffer(
                    to: periodPositionUs - backBufferDurationUs,
                    toKeyframe: retainBackBufferFromKeyframe
                )
            }

            try! resetRendererPosition(periodPositionUs: periodPositionUs)
            maybeContinueLoading()
        } else {
            periodQueue.clear()
            try! resetRendererPosition(periodPositionUs: periodPositionUs)
        }

        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
        handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)

        return periodPositionUs
    }

    private func resetRendererPosition(periodPositionUs: Int64) throws {
        let playingMediaPeriod = periodQueue.playing
        rendererPositionUs = if let playingMediaPeriod {
            playingMediaPeriod.toRendererTime(periodTime: periodPositionUs)
        } else {
            MediaPeriodQueue.initialRendererPositionOffsetUs + periodPositionUs
        }
        mediaClock.resetPosition(positionUs: rendererPositionUs)
        try! renderers.forEach {
            try! $0.resetPosition(for: playingMediaPeriod, positionUs: rendererPositionUs)
        }
        // TODO: notifyTrackSelectionDiscontinuity
    }

    private func setPlaybackParametersInternal(_ playbackParameters: PlaybackParameters) {
        assert(queue.isCurrent())
        mediaClock.setPlaybackParameters(new: playbackParameters)
        try! handlePlaybackParameters(
            playbackParameters: mediaClock.getPlaybackParameters(),
            acknowledgeCommand: true
        )
    }

    private func setSeekParametersInternal(_ seekParameters: SeekParameters) {
        assert(queue.isCurrent())
        self.seekParameters = seekParameters
    }

    private func setVideoOutputInternal(_ output: VideoSampleBufferRenderer) throws {
        try renderers.forEach { try $0.setVideoOutput(output) }
        if [.ready, .buffering].contains(playbackInfo.state) {
            handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
        }
    }

    private func removeVideoOutputInternal(_ output: VideoSampleBufferRenderer) throws {
        try renderers.forEach { try $0.removeVideoOutput(output) }
        if [.ready, .buffering].contains(playbackInfo.state) {
            handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
        }
    }

    private func stopInternal(forceResetRenderers: Bool, acknowledgeStop: Bool) {
        assert(queue.isCurrent())
        resetInternal(
            resetRenderers: forceResetRenderers,
            resetPosition: false,
            releaseMediaSourceList: true,
            resetError: false
        )
        playbackInfoUpdate.incrementPendingOperationAcks(acknowledgeStop ? 1 : 0)
        loadControl.onStopped(playerId: identifier)
        // TODO: audioQueue stop
        setState(.idle)
    }

    private func releaseInternal(continuation: CheckedContinuation<Void, Never>) {
        assert(queue.isCurrent())
        let finalBlock = { [self] in
            // TODO: handler stop
        }

        do {
            resetInternal(
                resetRenderers: true,
                resetPosition: false,
                releaseMediaSourceList: true,
                resetError: false
            )
            releaseRenderers()
            loadControl.onReleased(playerId: identifier)
            audioSessionManager.removePlayer(self, playerId: identifier)
            trackSelector.release()
            setState(.idle)
            continuation.resume()
        } catch {
            
        }
    }

    private func resetInternal(
        resetRenderers: Bool,
        resetPosition: Bool,
        releaseMediaSourceList: Bool,
        resetError: Bool
    ) {
        handler.removeMessages(SEPlayerMessageImpl.doSomeWork)
        pendingRecoverableRendererError = nil
        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtimeMs: true)
        mediaClock.stop()
        rendererPositionUs = MediaPeriodQueue.initialRendererPositionOffsetUs

        do {
            try! disableRenderers()
        } catch {
            print("Failed with error = \(error)"); fatalError() // TODO: do smth
        }

        if resetRenderers { renderers.forEach { $0.reset() } }
        enabledRendererCount = 0

        var mediaPeriodId = playbackInfo.periodId
        var startPositionUs = playbackInfo.positionUs
        var requestedContentPositionUs = if isUsingPlaceholderPeriod(playbackInfo: playbackInfo, period: period) {
            playbackInfo.requestedContentPositionUs
        } else {
            playbackInfo.positionUs
        }
        var resetTrackInfo = false
        if resetPosition {
            pendingInitialSeekPosition = nil
            let firstPeriodAndPositionUs = placeholderFirstMediaPeriodPositionUs(timeline: playbackInfo.timeline)
            mediaPeriodId = firstPeriodAndPositionUs.0
            startPositionUs = firstPeriodAndPositionUs.1
            requestedContentPositionUs = .timeUnset
            if mediaPeriodId != playbackInfo.periodId {
                resetTrackInfo = true
            }
        }

        periodQueue.clear()
        shouldContinueLoading = false

        let timeline = if releaseMediaSourceList, let timeline = playbackInfo.timeline as? PlaylistTimeline {
            timeline.copyWithPlaceholderTimeline(shuffleOrder: mediaSourceList.shuffleOrder)
        } else {
            playbackInfo.timeline
        }

        playbackInfo = PlaybackInfo(
            clock: clock,
            timeline: timeline,
            periodId: mediaPeriodId,
            requestedContentPositionUs: requestedContentPositionUs,
            discontinuityStartPositionUs: startPositionUs,
            state: playbackInfo.state,
            playbackError: resetError ? nil : playbackInfo.playbackError,
            isLoading: false,
            trackGroups: resetTrackInfo ? .empty : playbackInfo.trackGroups,
            trackSelectorResult: resetTrackInfo ? emptyTrackSelectorResult : playbackInfo.trackSelectorResult,
            loadingMediaPeriodId: mediaPeriodId,
            playWhenReady: playbackInfo.playWhenReady,
            playWhenReadyChangeReason: playbackInfo.playWhenReadyChangeReason,
            playbackSuppressionReason: playbackInfo.playbackSuppressionReason,
            playbackParameters: playbackInfo.playbackParameters,
            bufferedPositionUs: startPositionUs,
            totalBufferedDurationUs: 0,
            positionUs: startPositionUs,
            positionUpdateTimeMs: 0
        )

        if releaseMediaSourceList {
            periodQueue.releasePreloadPool()
            mediaSourceList.release()
        }
    }

    private func placeholderFirstMediaPeriodPositionUs(timeline: Timeline) -> (MediaPeriodId, Int64) {
        assert(queue.isCurrent())
        guard !timeline.isEmpty,
              let firstWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled),
              let (firtsPeriodId, positionUs) = timeline.periodPositionUs(window: window,
                                                                          period: period,
                                                                          windowIndex: firstWindowIndex,
                                                                          windowPositionUs: .timeUnset) else {
            return (PlaybackInfo.placeholderMediaPeriodId, Int64.zero)
        }

        let firstPeriodId = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
            timeline: timeline,
            periodId: firtsPeriodId,
            positionUs: .zero
        )

        return (firstPeriodId, positionUs)
    }

    private func sendMessageInternal(_ message: PlayerMessage) throws {
        if message.positionMs == .timeUnset {
            try sendMessageToTarget(message)
        } else if playbackInfo.timeline.isEmpty {
            pendingMessages.append(.init(message: message))
        } else {
            let pendingMessageInfo = PendingMessageInfo(message: message)
            if resolvePendingMessagePosition(
                pendingMessageInfo: pendingMessageInfo,
                newTimeline: playbackInfo.timeline,
                previousTimeline: playbackInfo.timeline,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                window: window,
                period: period
            ) {
                pendingMessages.append(pendingMessageInfo)
                pendingMessages.sort()
            } else {
                message.markAsProcessed(isDelivered: false)
            }
        }
    }

    private func sendMessageToTarget(_ message: PlayerMessage) throws {
        if message.queue === queue {
            Task {
                await deliverMessage(message, isolation: queue.playerActor())
                if [.ready, .buffering].contains(playbackInfo.state) {
                    handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
                }
            }
        } else {
            handler.obtainMessage(what: SEPlayerMessageImpl.sendMessageToTargetQueue(message)).sendToTarget()
        }
    }

    private func sendMessageToTargetQueue(_ message: PlayerMessage) throws {
        message.queue.execute {
            await self.deliverMessage(message, isolation: message.queue.playerActor())
        }
    }

    private func deliverMessage(_ message: PlayerMessage, isolation: isolated PlayerActor = #isolation) async {
        assert(message.queue.isCurrent())
        guard !message.isCanceled else { return }

        await message.target(message.type, message.payload)
        message.markAsProcessed(isDelivered: true)
    }

    private func resolvePendingMessagePositions(newTimeline: Timeline, previousTimeline: Timeline) {
        guard !newTimeline.isEmpty, !previousTimeline.isEmpty else {
            return
        }

        pendingMessages = pendingMessages.filter { message in
            if !resolvePendingMessagePosition(
                pendingMessageInfo: message,
                newTimeline: newTimeline,
                previousTimeline: previousTimeline,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                window: window,
                period: period
            ) {
                message.message.markAsProcessed(isDelivered: false)
                return false
            }
            return true
        }

        pendingMessages.sort()
    }

    private func maybeTriggerPendingMessages(oldPeriodPositionUs: Int64, newPeriodPositionUs: Int64) throws {
        if pendingMessages.isEmpty /* TODO: || playbackInfo.periodId.isAd */ {
            return
        }

        var oldPeriodPositionUs = oldPeriodPositionUs
        if deliverPendingMessageAtStartPositionRequired {
            oldPeriodPositionUs -= 1
            deliverPendingMessageAtStartPositionRequired = false
        }

        let currentPeriodIndex = playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId)
        var nextPendingMessageIndex = min(nextPendingMessageIndexHint, pendingMessages.count)
        var previousInfo = nextPendingMessageIndex > 0 ? pendingMessages[nextPendingMessageIndex - 1] : nil

        while let info = previousInfo {
            if (info.resolvedPeriodIndex > currentPeriodIndex ?? -1) || (info.resolvedPeriodIndex == currentPeriodIndex && info.resolvedPeriodTimeUs > oldPeriodPositionUs) {
                nextPendingMessageIndex -= 1
                previousInfo = nextPendingMessageIndex > 0 ? pendingMessages[nextPendingMessageIndex - 1] : nil
            } else {
                break
            }
        }

        var nextInfo = nextPendingMessageIndex < pendingMessages.count ? pendingMessages[nextPendingMessageIndex] : nil
        while let info = nextInfo {
            if info.resolvedPeriodUid != nil && (info.resolvedPeriodIndex < currentPeriodIndex ?? -1 || (info.resolvedPeriodIndex == currentPeriodIndex && info.resolvedPeriodTimeUs <= oldPeriodPositionUs)) {
                nextPendingMessageIndex += 1
                nextInfo = nextPendingMessageIndex < pendingMessages.count ? pendingMessages[nextPendingMessageIndex] : nil
            } else {
                break
            }
        }

        while let info = nextInfo, info.resolvedPeriodUid != nil,
              info.resolvedPeriodIndex == currentPeriodIndex,
              info.resolvedPeriodTimeUs > oldPeriodPositionUs,
              info.resolvedPeriodTimeUs <= newPeriodPositionUs {
            do {
                try sendMessageToTarget(info.message)
                if info.message.deleteAfterDelivery || info.message.isCanceled {
                    pendingMessages.remove(at: nextPendingMessageIndex)
                } else {
                    nextPendingMessageIndex += 1
                }
            } catch {
                if info.message.deleteAfterDelivery || info.message.isCanceled {
                    pendingMessages.remove(at: nextPendingMessageIndex)
                }

                throw error
            }

            nextInfo = nextPendingMessageIndex < pendingMessages.count ? pendingMessages[nextPendingMessageIndex] : nil
        }

        nextPendingMessageIndexHint = nextPendingMessageIndex
    }

    private func disableRenderers() throws {
        assert(queue.isCurrent())
        for index in 0..<renderers.count {
            try! disableRenderer(rendererIndex: index)
        }

        prewarmingMediaPeriodDiscontinuity = .timeUnset
    }

    private func disableRenderer(rendererIndex: Int) throws {
        assert(queue.isCurrent())
        let renderersBeforeDisabling = renderers[rendererIndex].enabledRendererCount
        try! renderers[rendererIndex].disable(mediaClock: mediaClock)
        maybeTriggerOnRendererReadyChanged(rendererIndex: rendererIndex, allowsPlayback: false)
        enabledRendererCount -= renderersBeforeDisabling
    }

    private func disableAndResetPrewarmingRenderers() {
        assert(queue.isCurrent())
        guard hasSecondaryRenderers, areRenderersPrewarming() else {
            return
        }

        for renderer in renderers {
            let renderersBeforeDisabling = renderer.enabledRendererCount
            renderer.disablePrewarming(mediaClock: mediaClock)
            enabledRendererCount -= renderersBeforeDisabling - renderer.enabledRendererCount
        }

        prewarmingMediaPeriodDiscontinuity = .timeUnset
    }

    private func isRendererPrewarmingMediaPeriod(rendererIndex: Int, mediaPeriodId: MediaPeriodId) -> Bool {
        assert(queue.isCurrent())
        guard let prewarming = periodQueue.prewarming else {
            return false
        }

        if prewarming.info.id != mediaPeriodId {
            return false
        } else {
            return renderers[rendererIndex].isPrewarming(period: prewarming)
        }
    }

    private func reselectTracksInternalAndSeek() throws {
        try reselectTracksInternal()
        try seekToCurrentPosition(sendDiscontinuity: true)
    }

    private func reselectTracksInternal() throws {
        let playbackSpeed = mediaClock.getPlaybackParameters().playbackRate
        var periodHolder = periodQueue.playing
        let readingPeriodHolder = periodQueue.reading
        var selectionsChangedForReadPeriod = true
        var newTrackSelectorResult: TrackSelectorResult
        // Keep playing period result in case of track selection change for reading period only.
        var newPlayingPeriodTrackSelectorResult: TrackSelectorResult?

        while true {
            guard let periodHolderCopy = periodHolder, periodHolderCopy.isPrepared else {
                // The reselection did not change any prepared periods.
                return
            }

            newTrackSelectorResult = try periodHolderCopy.selectTracks(
                playbackSpeed: playbackSpeed,
                timeline: playbackInfo.timeline,
                playWhenReady: playbackInfo.playWhenReady
            )

            if periodHolderCopy == periodQueue.playing {
                newPlayingPeriodTrackSelectorResult = newTrackSelectorResult
            }

            if newTrackSelectorResult != periodHolderCopy.trackSelectorResults {
                break
            }

            if periodHolderCopy == readingPeriodHolder {
                // The track reselection didn't affect any period that has been read.
                selectionsChangedForReadPeriod = false
            }

            periodHolder = periodHolderCopy.next
        }

        if selectionsChangedForReadPeriod {
            guard let playingPeriodHolder = periodQueue.playing,
                  let newPlayingPeriodTrackSelectorResult else {
                fatalError(); return
            }
            let removeAfterResult = periodQueue.removeAfter(mediaPeriodHolder: playingPeriodHolder)
            let recreateStreams = removeAfterResult.contains(.alteredReadingPeriod)
            var streamResetFlags = Array(repeating: false, count: renderers.count)

            let periodPositionUs = playingPeriodHolder.applyTrackSelection(
                newTrackSelectorResult: newPlayingPeriodTrackSelectorResult,
                positionUs: playbackInfo.positionUs,
                forceRecreateStreams: recreateStreams,
                streamResetFlags: &streamResetFlags
            )

            let hasDiscontinuity = playbackInfo.state != .ended && periodPositionUs != playbackInfo.positionUs
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: playbackInfo.periodId,
                positionUs: periodPositionUs,
                requestedContentPositionUs: playbackInfo.requestedContentPositionUs,
                discontinuityStartPositionUs: playbackInfo.discontinuityStartPositionUs,
                reportDiscontinuity: hasDiscontinuity,
                discontinuityReason: .internal
            )

            if hasDiscontinuity {
                try resetRendererPosition(periodPositionUs: periodPositionUs)
            }

            disableAndResetPrewarmingRenderers()

            var rendererWasEnabledFlags = Array(repeating: false, count: renderers.count)
            for (index, renderer) in renderers.enumerated() {
                let enabledRendererCountBeforeDisabling = renderer.enabledRendererCount
                rendererWasEnabledFlags[index] = renderer.isRendererEnabled

                guard let sampleStream = playingPeriodHolder.sampleStreams[index] else {
                    continue
                }

                try renderer.maybeDisableOrResetPosition(
                    sampleStream: sampleStream,
                    mediaClock: mediaClock,
                    rendererPositionUs: rendererPositionUs,
                    streamReset: streamResetFlags[index]
                )

                if enabledRendererCountBeforeDisabling - renderer.enabledRendererCount > 0 {
                    maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: false)
                }

                enabledRendererCount -= enabledRendererCountBeforeDisabling - renderer.enabledRendererCount
            }

            try enableRenderers(
                rendererWasEnabledFlags: rendererWasEnabledFlags,
                startPositionUs: rendererPositionUs
            )
            playingPeriodHolder.allRenderersInCorrectState = true
        } else {
            guard let periodHolder else { return }
            periodQueue.removeAfter(mediaPeriodHolder: periodHolder)
            if periodHolder.isPrepared {
                let loadingPeriodPositionUs = max(
                    periodHolder.info.startPositionUs,
                    periodHolder.toPeriodTime(rendererTime: rendererPositionUs)
                )

                if hasSecondaryRenderers,
                   areRenderersPrewarming(),
                   periodQueue.prewarming == periodHolder {
                    disableAndResetPrewarmingRenderers()
                }

                periodHolder.applyTrackSelection(
                    trackSelectorResult: newTrackSelectorResult,
                    positionUs: loadingPeriodPositionUs,
                    forceRecreateStreams: false
                )
            }
        }

        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: true)
        if playbackInfo.state != .ended {
            maybeContinueLoading()
            try updatePlaybackPositions()
            handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
        }
    }

    private func updateTrackSelectionPlaybackSpeed(playbackSpeed: Float) {
        // TODO: make
    }

    private func notifyTrackSelectionDiscontinuity() {
        // TODO: make
    }

    private func shouldTransitionToReadyState(renderersReadyOrEnded: Bool) -> Bool {
        guard enabledRendererCount > 0 else { return isTimelineReady() }
        guard renderersReadyOrEnded else { return false }
        guard playbackInfo.isLoading else { return true }
        guard let playingPeriodHolder = periodQueue.playing,
              let loadingHolder = periodQueue.loading else { return false }

        let isBufferedToEnd = loadingHolder.isFullyBuffered() && loadingHolder.info.isFinal
        guard !isBufferedToEnd else { return true }

        let bufferedDurationUs = getTotalBufferedDurationUs(
            bufferedPositionInLoadingPeriodUs: loadingHolder.getBufferedPositionUs()
        )

        return loadControl.shouldStartPlayback(
            parameters: LoadControlParams(
                playerId: identifier,
                timeline: playbackInfo.timeline,
                mediaPeriodId: playingPeriodHolder.info.id,
                playbackPositionUs: playingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs),
                bufferedDurationUs: bufferedDurationUs,
                playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                playWhenReady: playbackInfo.playWhenReady,
                rebuffering: isRebuffering,
                targetLiveOffsetUs: .timeUnset,
                lastRebufferRealtimeMs: lastRebufferRealtimeMs
            )
        )
    }

    private func isTimelineReady() -> Bool {
        guard let playingPeriodHolder = periodQueue.playing else {
            return false
        }

        let playingPeriodDurationUs = playingPeriodHolder.info.durationUs
        return playingPeriodHolder.isPrepared
            && (playingPeriodDurationUs == .timeUnset
                || playbackInfo.positionUs < playingPeriodDurationUs
                || !shouldPlayWhenReady())
    }

    private func handleMediaSourceListInfoRefreshed(timeline: Timeline, isSourceRefresh: Bool) {
        let positionUpdate = resolvePositionForPlaylistChange(
            timeline: timeline,
            playbackInfo: playbackInfo,
            pendingInitialSeekPosition: pendingInitialSeekPosition,
            queue: periodQueue,
            repeatMode: repeatMode,
            shuffleModeEnabled: shuffleModeEnabled,
            window: window,
            period: period
        )

        let newPeriodId = positionUpdate.periodId
        let newRequestedContentPositionUs = positionUpdate.requestedContentPositionUs
        let forceBufferingState = positionUpdate.forceBufferingState
        var newPositionUs = positionUpdate.periodPositionUs
        let periodPositionChanged = playbackInfo.periodId != newPeriodId || newPositionUs != playbackInfo.positionUs

        if positionUpdate.endPlayback {
            if playbackInfo.state != .idle {
                setState(.ended)
            }
            resetInternal(
                resetRenderers: false,
                resetPosition: false,
                releaseMediaSourceList: false,
                resetError: true
            )
        }
        renderers.forEach { $0.setTimeline(timeline) }

        if !periodPositionChanged {
            let maxRendererReadPositionUs: Int64 = if let reading = periodQueue.reading {
                self.maxRendererReadPositionUs(periodHolder: reading)
            } else {
                .zero
            }

            let maxRendererPrewarmingPositionUs: Int64 = if let prewarming = periodQueue.prewarming, !areRenderersPrewarming() {
                self.maxRendererReadPositionUs(periodHolder: prewarming)
            } else {
                .zero
            }

            let updateQueuedPeriodsResult = periodQueue.updateQueuedPeriods(
                timeline: timeline,
                rendererPositionUs: rendererPositionUs,
                maxRendererReadPositionUs: maxRendererReadPositionUs,
                maxRendererPrewarmingPositionUs: maxRendererPrewarmingPositionUs
            )

            if updateQueuedPeriodsResult.contains(.alteredReadingPeriod) {
                try! seekToCurrentPosition(sendDiscontinuity: false)
            } else if updateQueuedPeriodsResult.contains(.alteredPrewarmingPeriod) {
                disableAndResetPrewarmingRenderers()
            }
        } else if !timeline.isEmpty {
            var periodHolder = periodQueue.playing
            while let unwrappedPeriodHolder = periodHolder {
                if unwrappedPeriodHolder.info.id == newPeriodId {
                    unwrappedPeriodHolder.info = periodQueue.updatedMediaPeriodInfo(
                        with: unwrappedPeriodHolder.info,
                        timeline: timeline
                    )
                    // TODO: periodHolder.updateClipping
                }
                periodHolder = unwrappedPeriodHolder.next
            }

            newPositionUs = try! seekToPeriodPosition(
                periodId: newPeriodId,
                periodPositionUs: newPositionUs,
                forceBufferingState: forceBufferingState
            )
        }

        try! updatePlaybackSpeedSettingsForNewPeriod(
            newTimeline: timeline,
            newPeriodId: newPeriodId,
            oldTimeline: playbackInfo.timeline,
            oldPeriodId: playbackInfo.periodId,
            positionForTargetOffsetOverrideUs: positionUpdate.setTargetLiveOffset ? newPositionUs : .timeUnset,
            forceSetTargetOffsetOverride: false
        )

        if periodPositionChanged || newRequestedContentPositionUs != playbackInfo.requestedContentPositionUs {
            let oldPeriodId = playbackInfo.periodId.periodId
            let oldTimeline = playbackInfo.timeline
            let reportDiscontinuity = periodPositionChanged
            && isSourceRefresh
            && !oldTimeline.isEmpty
            && !oldTimeline.periodById(oldPeriodId, period: period).isPlaceholder

            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: newPeriodId,
                positionUs: newPositionUs,
                requestedContentPositionUs: newRequestedContentPositionUs,
                discontinuityStartPositionUs: playbackInfo.discontinuityStartPositionUs,
                reportDiscontinuity: reportDiscontinuity,
                discontinuityReason: timeline.indexOfPeriod(by: oldPeriodId) == nil ? .remove : .skip
            )
        }

        resetPendingPauseAtEndOfPeriod()
        resolvePendingMessagePositions(newTimeline: timeline, previousTimeline: playbackInfo.timeline)
        playbackInfo = playbackInfo.timeline(timeline)
        if !timeline.isEmpty {
            pendingInitialSeekPosition = nil
        }
        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
        handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
    }

    private func updatePlaybackSpeedSettingsForNewPeriod(
        newTimeline: Timeline,
        newPeriodId: MediaPeriodId,
        oldTimeline: Timeline,
        oldPeriodId: MediaPeriodId,
        positionForTargetOffsetOverrideUs: Int64,
        forceSetTargetOffsetOverride: Bool
    ) throws {
        // TODO: live speed control
        if mediaClock.getPlaybackParameters() != playbackInfo.playbackParameters {
            mediaClock.setPlaybackParameters(new: playbackInfo.playbackParameters)
            try! handlePlaybackParameters(
                playbackParameters: playbackInfo.playbackParameters,
                currentPlaybackSpeed: playbackInfo.playbackParameters.playbackRate,
                updatePlaybackInfo: false,
                acknowledgeCommand: false
            )

            return
        }
    }

    private func maxRendererReadPositionUs(periodHolder: MediaPeriodHolder?) -> Int64 {
        assert(queue.isCurrent())
        guard let periodHolder else { return .zero }

        var maxReadPositionUs = periodHolder.renderPositionOffset
        guard periodHolder.isPrepared else { return maxReadPositionUs }

        for renderer in renderers where !renderer.isReading(from: periodHolder) {
            let readingPositionUs = renderer.readingPositionUs(for: periodHolder)
            if readingPositionUs == .endOfSource {
                return .endOfSource
            } else {
                maxReadPositionUs = max(readingPositionUs, maxReadPositionUs)
            }
        }

        return maxReadPositionUs
    }

    private func updatePeriods() throws {
        if playbackInfo.timeline.isEmpty || !mediaSourceList.isPrepared {
            return
        }

        let loadingPeriodChanged = try! maybeUpdateLoadingPeriod()
        try! maybeUpdatePrewarmingPeriod()
        try! maybeUpdateReadingPeriod()
        try! maybeUpdateReadingRenderers()
        try! maybeUpdatePlayingPeriod()
        try! maybeUpdatePreloadPeriods(loadingPeriodChanged: loadingPeriodChanged)
    }

    private func maybeUpdateLoadingPeriod() throws -> Bool {
        var loadingPeriodChanged = false
        periodQueue.reevaluateBuffer(rendererPositionUs: rendererPositionUs)
        if periodQueue.shouldLoadNextMediaPeriod(),
           let info = periodQueue.nextMediaPeriodInfo(rendererPositionUs: rendererPositionUs, playbackInfo: playbackInfo) {
            let mediaPeriodHolder = try! periodQueue.enqueueNextMediaPeriodHolder(info: info)
            if !mediaPeriodHolder.prepareCalled {
                mediaPeriodHolder.prepare(callback: self, on: info.startPositionUs)
            } else if mediaPeriodHolder.isPrepared {
                didPrepare(mediaPeriod: mediaPeriodHolder.mediaPeriod)
            }

            if periodQueue.playing === mediaPeriodHolder {
                try! resetRendererPosition(periodPositionUs: info.startPositionUs)
            }

            handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
            loadingPeriodChanged = true
        }

        if shouldContinueLoading {
            shouldContinueLoading = isLoadingPossible(mediaPeriodHolder: periodQueue.loading)
            updateIsLoading()
        } else {
            maybeContinueLoading()
        }

        return loadingPeriodChanged
    }

    private func maybeUpdatePrewarmingPeriod() throws {
        guard !pendingPauseAtEndOfPeriod,
              hasSecondaryRenderers,
              !isPrewarmingDisabledUntilNextTransition,
              !areRenderersPrewarming() else {
            return
        }

        guard let prewarmingPeriodHolder = periodQueue.prewarming,
              prewarmingPeriodHolder == periodQueue.playing,
              let next = prewarmingPeriodHolder.next,
              next.isPrepared else {
            return
        }

        periodQueue.advancePrewarmingPeriod()
        try! maybePrewarmRenderers()
    }

    private func maybePrewarmRenderers() throws {
        guard let prewarmingPeriod = periodQueue.prewarming else {
            return
        }

        let trackSelectorResult = prewarmingPeriod.trackSelectorResults
        for (index, renderer) in renderers.enumerated() {
            if trackSelectorResult.isRendererEnabled(for: index),
               renderer.hasSecondary, !renderer.isPrewarming {
                renderer.startPrewarming()
                try! enableRenderer(
                    periodHolder: prewarmingPeriod,
                    rendererIndex: index,
                    wasRendererEnabled: false,
                    startPositionUs: prewarmingPeriod.getStartPositionRendererTime()
                )
            }
        }

        if areRenderersPrewarming() {
            prewarmingMediaPeriodDiscontinuity = prewarmingPeriod.mediaPeriod.readDiscontinuity()
            if !prewarmingPeriod.isFullyBuffered() {
                periodQueue.removeAfter(mediaPeriodHolder: prewarmingPeriod)
                handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                maybeContinueLoading()
            }
        }
    }

    private func maybeUpdateReadingPeriod() throws {
        guard let readingPeriodHolder = periodQueue.reading else {
            return
        }

        guard let next = readingPeriodHolder.next, !pendingPauseAtEndOfPeriod else {
            if readingPeriodHolder.info.isFinal || pendingPauseAtEndOfPeriod {
                for renderer in renderers where
                renderer.isReading(from: readingPeriodHolder) &&
                renderer.didReadStreamToEnd(for: readingPeriodHolder) {
                    let streamEndPositionUs: Int64 = if readingPeriodHolder.info.durationUs != .timeUnset,
                                                        readingPeriodHolder.info.durationUs != .endOfSource {
                        readingPeriodHolder.renderPositionOffset + readingPeriodHolder.info.durationUs
                    } else {
                        .timeUnset
                    }
                    renderer.setCurrentStreamFinal(for: readingPeriodHolder, streamEndPositionUs: streamEndPositionUs)
                }
            }

            return
        }

        if !hasReadingPeriodFinishedReading() {
            return
        }

        if areRenderersPrewarming() && periodQueue.prewarming == periodQueue.reading {
            return
        }

        if !next.isPrepared
            && rendererPositionUs < next.getStartPositionRendererTime() {
            return
        }
//        guard next.isPrepared, rendererPositionUs > next.getStartPositionRenderTime() else {
//            return
//        }

        let oldReadingPeriodHolder = readingPeriodHolder
        let oldTrackSelectorResult = readingPeriodHolder.trackSelectorResults
        guard let readingPeriodHolder = periodQueue.advanceReadingPeriod() else { return }
        let newTrackSelectorResult = readingPeriodHolder.trackSelectorResults

        try! updatePlaybackSpeedSettingsForNewPeriod(
            newTimeline: playbackInfo.timeline,
            newPeriodId: readingPeriodHolder.info.id,
            oldTimeline: playbackInfo.timeline,
            oldPeriodId: oldReadingPeriodHolder.info.id,
            positionForTargetOffsetOverrideUs: .timeUnset,
            forceSetTargetOffsetOverride: false
        )

        if readingPeriodHolder.isPrepared,
           (hasSecondaryRenderers && prewarmingMediaPeriodDiscontinuity != .timeUnset) ||
            (readingPeriodHolder.mediaPeriod.readDiscontinuity() != .timeUnset) {
            prewarmingMediaPeriodDiscontinuity = .timeUnset

            var arePrewarmingRenderersHandlingDiscontinuity = hasSecondaryRenderers && !isPrewarmingDisabledUntilNextTransition
            if arePrewarmingRenderersHandlingDiscontinuity {
                for (index, renderer) in renderers.enumerated() where newTrackSelectorResult.isRendererEnabled(for: index) {
                    // TODO: check for MimeType for all sync samples in format
                    if !renderer.isPrewarming {
                        arePrewarmingRenderersHandlingDiscontinuity = false
                        break
                    }
                }
            }

            if !arePrewarmingRenderersHandlingDiscontinuity {
                setAllNonPrewarmingRendererStreamsFinal(
                    streamEndPositionUs: readingPeriodHolder.getStartPositionRendererTime()
                )
                if !readingPeriodHolder.isFullyBuffered() {
                    periodQueue.removeAfter(mediaPeriodHolder: readingPeriodHolder)
                    handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                    maybeContinueLoading()
                }
                
                return
            }
        }

        renderers.forEach {
            $0.maybeSetOldStreamToFinal(
                oldTrackSelectorResult: oldTrackSelectorResult,
                newTrackSelectorResult: newTrackSelectorResult,
                streamEndPositionUs: readingPeriodHolder.getStartPositionRendererTime()
            )
        }
    }

    private func maybeUpdateReadingRenderers() throws {
        guard let readingPeriod = periodQueue.reading,
              periodQueue.playing != readingPeriod,
              !readingPeriod.allRenderersInCorrectState else {
            return
        }

        if try! updateRenderersForTransition() {
            readingPeriod.allRenderersInCorrectState = true
        }
    }

    private func updateRenderersForTransition() throws -> Bool {
        guard let readingMediaPeriod = periodQueue.reading else { return false }
        let newTrackSelectorResult = readingMediaPeriod.trackSelectorResults
        var allUpdated = true

        for renderer in renderers {
            let enabledRendererPreTransition = renderer.enabledRendererCount
            let result = try! renderer.replaceStreamsOrDisableRendererForTransition(
                readingPeriodHolder: readingMediaPeriod,
                newTrackSelectorResult: newTrackSelectorResult,
                mediaClock: mediaClock
            )

            enabledRendererCount -= enabledRendererPreTransition - renderer.enabledRendererCount
            allUpdated = allUpdated && result
        }

//        try renderers.forEach { try $0.setControlTimebase(clock.timebase) }
        if allUpdated {
            for (index, renderer) in renderers.enumerated() {
                if newTrackSelectorResult.isRendererEnabled(for: index), !renderer.isReading(from: readingMediaPeriod) {
                    try! enableRenderer(
                        periodHolder: readingMediaPeriod,
                        rendererIndex: index,
                        wasRendererEnabled: false,
                        startPositionUs: readingMediaPeriod.getStartPositionRendererTime()
                    )
                }
            }
        }

        return allUpdated
    }

    private func maybeUpdatePreloadPeriods(loadingPeriodChanged: Bool) throws {
        guard preloadConfiguration.targetPreloadDurationUs != .timeUnset else {
            return
        }

        if loadingPeriodChanged || !playbackInfo.timeline.equals(to: lastPreloadPoolInvalidationTimeline) {
            lastPreloadPoolInvalidationTimeline = playbackInfo.timeline
            try! periodQueue.invalidatePreloadPool(timeline: playbackInfo.timeline)
        }

        maybeContinuePreloading()
    }

    private func maybeContinuePreloading() {
        periodQueue.maybeUpdatePreloadMediaPeriodHolder()
        guard let preloading = periodQueue.preloading,
              !preloading.prepareCalled, preloading.isPrepared,
              !preloading.mediaPeriod.isLoading,
              loadControl.shouldContinuePreloading(
                timeline: playbackInfo.timeline,
                mediaPeriodId: preloading.info.id,
                bufferedDurationUs: preloading.isPrepared ? preloading.mediaPeriod.getBufferedPositionUs() : .zero)
        else {
            return
        }

        if !preloading.prepareCalled {
            preloading.prepare(callback: self, on: preloading.info.startPositionUs)
        } else {
            preloading.continueLoading(
                loadingInfo: LoadingInfo(
                    playbackPosition: preloading.toPeriodTime(rendererTime: rendererPositionUs),
                    playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                    lastRebufferRealtime: lastRebufferRealtimeMs
                )
            )
        }
    }

    private func maybeUpdatePlayingPeriod() throws {
        var advancedPlayingPeriod = false
        while shouldAdvancePlayingPeriod() {
            if advancedPlayingPeriod {
                maybeNotifyPlaybackInfoChanged()
            }

            isPrewarmingDisabledUntilNextTransition = false
            guard let newPlayingPeriodHolder = periodQueue.advancePlayingPeriod() else {
                // TODO: throw error
                fatalError()
            }

            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: newPlayingPeriodHolder.info.id,
                positionUs: newPlayingPeriodHolder.info.startPositionUs,
                requestedContentPositionUs: newPlayingPeriodHolder.info.requestedContentPositionUs,
                discontinuityStartPositionUs: newPlayingPeriodHolder.info.startPositionUs,
                reportDiscontinuity: true,
                discontinuityReason: .autoTransition
            )

            resetPendingPauseAtEndOfPeriod()
            try! updatePlaybackPositions()
            if areRenderersPrewarming(), newPlayingPeriodHolder == periodQueue.prewarming {
                try! maybeHandlePrewarmingTransition()
            }

            if playbackInfo.state == .ready {
                try! startRenderers()
            }

            allowRenderersToRenderStartOfStreams()
            advancedPlayingPeriod = true
        }
    }

    private func maybeHandlePrewarmingTransition() throws {
        try! renderers.forEach { try! $0.maybeHandlePrewarmingTransition() }
    }

    private func allowRenderersToRenderStartOfStreams() {
        guard let playingTracks = periodQueue.playing?.trackSelectorResults else {
            return
        }

        for (index, renderer) in renderers.enumerated() where playingTracks.isRendererEnabled(for: index) {
            renderer.enableMayRenderStartOfStream()
        }
    }

    func resetPendingPauseAtEndOfPeriod() {
        pendingPauseAtEndOfPeriod = if let playingPeriod = periodQueue.playing {
            playingPeriod.info.isLastInTimelineWindow && pauseAtEndOfWindow
        } else {
            false
        }
    }

    private func shouldAdvancePlayingPeriod() -> Bool {
        guard shouldPlayWhenReady(),
              !pendingPauseAtEndOfPeriod,
              let playingPeriodHolder = periodQueue.playing,
              let nextPlayingPeriodHolder = playingPeriodHolder.next else { return false }

        let result = rendererPositionUs >= nextPlayingPeriodHolder.getStartPositionRendererTime()
            && nextPlayingPeriodHolder.allRenderersInCorrectState

        return result
    }

    private func hasReadingPeriodFinishedReading() -> Bool {
        guard let reading = periodQueue.reading,
              reading.isPrepared else { return false }

        return renderers.allSatisfy { $0.hasFinishedReading(from: reading) }
    }

    private func setAllNonPrewarmingRendererStreamsFinal(streamEndPositionUs: Int64) {
        renderers.forEach {
            $0.setAllNonPrewarmingRendererStreamsFinal(streamEndPositionUs: streamEndPositionUs)
        }
    }

    private func handlePeriodPrepared(mediaPeriod: MediaPeriod) throws {
        assert(queue.isCurrent())
        if periodQueue.isLoading(mediaPeriod: mediaPeriod) {
            guard let loadingPeriod = periodQueue.loading else {
                return
            }
            try! handleLoadingPeriodPrepared(loadingPeriodHolder: loadingPeriod)
        } else {
            guard let preloadHolder = periodQueue.preloading,
                  preloadHolder.isPrepared else {
                return
            }
            
            try preloadHolder.handlePrepared(
                playbackSpeed: playbackInfo.playbackParameters.playbackRate,
                timeline: playbackInfo.timeline,
                playWhenReady: playbackInfo.playWhenReady
            )
            if periodQueue.isPreloading(mediaPeriod: mediaPeriod) {
                maybeContinuePreloading()
            }
        }
    }

    private func handleLoadingPeriodPrepared(loadingPeriodHolder: MediaPeriodHolder) throws {
        if !loadingPeriodHolder.isPrepared {
            try loadingPeriodHolder.handlePrepared(
                playbackSpeed: playbackInfo.playbackParameters.playbackRate,
                timeline: playbackInfo.timeline,
                playWhenReady: playbackInfo.playWhenReady
            )
        }

        updateLoadControlTrackSelection(
            mediaPeriodId: loadingPeriodHolder.info.id,
            trackGroups: loadingPeriodHolder.trackGroups,
            trackSelectorResult: loadingPeriodHolder.trackSelectorResults
        )

        if loadingPeriodHolder === periodQueue.playing {
            try! resetRendererPosition(periodPositionUs: loadingPeriodHolder.info.startPositionUs)
            try! enableRenderers()
            loadingPeriodHolder.allRenderersInCorrectState = true
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: playbackInfo.periodId,
                positionUs: loadingPeriodHolder.info.startPositionUs,
                requestedContentPositionUs: playbackInfo.requestedContentPositionUs,
                discontinuityStartPositionUs: loadingPeriodHolder.info.startPositionUs,
                reportDiscontinuity: false,
                discontinuityReason: .internal
            )
        }
        maybeContinueLoading()
    }

    private func handleContinueLoadingRequested(mediaPeriod: MediaPeriod) {
        if periodQueue.isLoading(mediaPeriod: mediaPeriod) {
            maybeContinueLoading()
        } else if periodQueue.isPreloading(mediaPeriod: mediaPeriod) {
            maybeContinuePreloading()
        }
    }

    private func handlePlaybackParameters(playbackParameters: PlaybackParameters, acknowledgeCommand: Bool) throws {
        try! handlePlaybackParameters(
            playbackParameters: playbackParameters,
            currentPlaybackSpeed: playbackParameters.playbackRate,
            updatePlaybackInfo: true,
            acknowledgeCommand: acknowledgeCommand
        )
    }

    private func handlePlaybackParameters(
        playbackParameters: PlaybackParameters,
        currentPlaybackSpeed: Float,
        updatePlaybackInfo: Bool,
        acknowledgeCommand: Bool
    ) throws {
        if updatePlaybackInfo {
            if acknowledgeCommand {
                playbackInfoUpdate.incrementPendingOperationAcks(1)
            }
            playbackInfo = playbackInfo.playbackParameters(playbackParameters)
        }
        // TODO: updateTrackSelectionPlaybackSpeed
        try! renderers.forEach {
            try! $0.setPlaybackSpeed(current: currentPlaybackSpeed, target: playbackParameters.playbackRate)
        }
    }

    private func maybeContinueLoading() {
        shouldContinueLoading = shouldContinueLoadingPeriod()
        if shouldContinueLoading, let loadingPeriod = periodQueue.loading {
            loadingPeriod.continueLoading(loadingInfo: .init(
                playbackPosition: loadingPeriod.toPeriodTime(rendererTime: rendererPositionUs),
                playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                lastRebufferRealtime: lastRebufferRealtimeMs
            ))
        }
        updateIsLoading()
    }

    private func shouldContinueLoadingPeriod() -> Bool {
        guard let loadingPeriod = periodQueue.loading, isLoadingPossible(mediaPeriodHolder: loadingPeriod) else {
            return false
        }

        let bufferedDurationUs = getTotalBufferedDurationUs(
            bufferedPositionInLoadingPeriodUs: loadingPeriod.getNextLoadPosition()
        )

        let playbackPositionUs = if loadingPeriod == periodQueue.playing {
            loadingPeriod.toPeriodTime(rendererTime: rendererPositionUs)
        } else {
            loadingPeriod.toPeriodTime(rendererTime: rendererPositionUs) - loadingPeriod.info.startPositionUs
        }

        let loadParameters = LoadControlParams(
            playerId: identifier,
            timeline: playbackInfo.timeline,
            mediaPeriodId: loadingPeriod.info.id,
            playbackPositionUs: playbackPositionUs,
            bufferedDurationUs: bufferedDurationUs,
            playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
            playWhenReady: playbackInfo.playWhenReady,
            rebuffering: isRebuffering,
            targetLiveOffsetUs: .timeUnset,
            lastRebufferRealtimeMs: lastRebufferRealtimeMs
        )

        var shouldContinueLoading = loadControl.shouldContinueLoading(with: loadParameters)

        if let playing = periodQueue.playing, !shouldContinueLoading,
           playing.isPrepared, bufferedDurationUs < 500_000, // TODO: conts
           backBufferDurationUs > 0 || retainBackBufferFromKeyframe {
            playing.mediaPeriod.discardBuffer(to: playbackInfo.positionUs, toKeyframe: false)
            shouldContinueLoading = loadControl.shouldContinueLoading(with: loadParameters)
        }

        return shouldContinueLoading
    }

    private func isLoadingPossible(mediaPeriodHolder: MediaPeriodHolder?) -> Bool {
        guard let mediaPeriodHolder else { return false }

        return mediaPeriodHolder.getNextLoadPosition() != .endOfSource
    }

    private func updateIsLoading() {
        let loadingPeriod = periodQueue.loading
        let isLoading = shouldContinueLoading || loadingPeriod?.mediaPeriod.isLoading ?? false
        if isLoading != playbackInfo.isLoading {
            playbackInfo = playbackInfo.isLoading(isLoading)
        }
    }

    private func handlePositionDiscontinuity(
        mediaPeriodId: MediaPeriodId,
        positionUs: Int64,
        requestedContentPositionUs: Int64,
        discontinuityStartPositionUs: Int64,
        reportDiscontinuity: Bool,
        discontinuityReason: DiscontinuityReason
    ) -> PlaybackInfo {
        deliverPendingMessageAtStartPositionRequired = deliverPendingMessageAtStartPositionRequired
            || positionUs != playbackInfo.positionUs
            || mediaPeriodId != playbackInfo.periodId

        resetPendingPauseAtEndOfPeriod()
        var trackGroupArray = playbackInfo.trackGroups
        var trackSelectorResult = playbackInfo.trackSelectorResult

        if mediaSourceList.isPrepared {
            let playingPeriodHolder = periodQueue.playing
            trackGroupArray = playingPeriodHolder?.trackGroups ?? .empty
            trackSelectorResult = playingPeriodHolder?.trackSelectorResults ?? emptyTrackSelectorResult

            if let playingPeriodHolder,
               playingPeriodHolder.info.requestedContentPositionUs != requestedContentPositionUs {
                playingPeriodHolder.info = playingPeriodHolder.info.copyWithRequestedContentPositionUs(requestedContentPositionUs)
            }
        } else if mediaPeriodId != playbackInfo.periodId {
            trackGroupArray = .empty
            trackSelectorResult = emptyTrackSelectorResult
        }
        if reportDiscontinuity {
            playbackInfoUpdate.setPositionDiscontinuity(discontinuityReason)
        }
        return playbackInfo.positionUs(
            periodId: mediaPeriodId,
            positionUs: positionUs,
            requestedContentPositionUs: requestedContentPositionUs,
            discontinuityStartPositionUs: discontinuityStartPositionUs,
            totalBufferedDurationUs: getTotalBufferedDurationUs(),
            trackGroups: trackGroupArray,
            trackSelectorResult: trackSelectorResult
        )
    }

    private func enableRenderers() throws {
        guard let readingPeriod = periodQueue.reading else {
            assertionFailure()
            return
        }
        try! enableRenderers(
            rendererWasEnabledFlags: Array(
                repeating: false,
                count: renderers.count
            ),
            startPositionUs: readingPeriod.getStartPositionRendererTime()
        )
    }

    private func enableRenderers(rendererWasEnabledFlags: [Bool], startPositionUs: Int64) throws {
        guard let readingMediaPeriod = periodQueue.reading else {
            return
        }
        let trackSelectorResult = readingMediaPeriod.trackSelectorResults
        for (index, renderer) in renderers.enumerated() {
            if !trackSelectorResult.isRendererEnabled(for: index) {
                renderer.reset()
            }
        }

        for (index, renderer) in renderers.enumerated() {
            if trackSelectorResult.isRendererEnabled(for: index),
               !renderer.isReading(from: readingMediaPeriod) {
                try! enableRenderer(
                    periodHolder: readingMediaPeriod,
                    rendererIndex: index,
                    wasRendererEnabled: rendererWasEnabledFlags[index],
                    startPositionUs: startPositionUs
                )
            }
        }
    }

    private func enableRenderer(
        periodHolder: MediaPeriodHolder,
        rendererIndex: Int,
        wasRendererEnabled: Bool,
        startPositionUs: Int64
    ) throws {
        let renderer = renderers[rendererIndex]
        guard !renderer.isRendererEnabled else { return }

        let playingAndReadingTheSamePeriod = periodQueue.playing === periodHolder
        let trackSelectorResult = periodHolder.trackSelectorResults
//        let rendererConfiguration = trackSelectorResult.renderersConfig[rendererIndex]
        guard let newSelection = trackSelectorResult.selections[rendererIndex],
              let sampleStream = periodHolder.sampleStreams[rendererIndex] else {
            return
        }

        let playing = shouldPlayWhenReady() && playbackInfo.state == .ready
        let joining = !wasRendererEnabled && playing
        enabledRendererCount += 1

        try! renderer.enable(
            trackSelection: newSelection,
            stream: sampleStream,
            positionUs: rendererPositionUs,
            joining: joining,
            mayRenderStartOfStream: playingAndReadingTheSamePeriod,
            startPositionUs: startPositionUs,
            offsetUs: periodHolder.renderPositionOffset,
            mediaPeriodId: periodHolder.info.id,
            mediaClock: mediaClock
        )

//        try renderer.handleMessage(
//            .requestMediaDataWhenReady(queue: queue, block: { [self] in
////                handler.sendEmptyMessage(SEPlayerMessageImpl.doSomeWork)
//            }),
//            mediaPeriod: periodHolder
//        )

        if playing, playingAndReadingTheSamePeriod {
            try! renderer.start()
        }
    }

    private func releaseRenderers() {
        renderers.forEach { $0.release() }
    }

    func handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: Bool) {
        let loading = periodQueue.loading
        let loadingMediaPeriodId = if let loading {
            loading.info.id
        } else {
            playbackInfo.periodId
        }

        let loadingMediaPeriodChanged = playbackInfo.loadingMediaPeriodId != loadingMediaPeriodId
        if loadingMediaPeriodChanged {
            playbackInfo = playbackInfo.loadingMediaPeriodId(loadingMediaPeriodId)
        }

        playbackInfo.bufferedPositionUs = if let loading {
            loading.getBufferedPositionUs()
        } else {
            playbackInfo.positionUs
        }
        playbackInfo.totalBufferedDurationUs = getTotalBufferedDurationUs()

        if loadingMediaPeriodChanged || loadingTrackSelectionChanged,
           let loading, loading.isPrepared {
            updateLoadControlTrackSelection(
                mediaPeriodId: loading.info.id,
                trackGroups: loading.trackGroups,
                trackSelectorResult: loading.trackSelectorResults
            )
        }
    }

    private func getTotalBufferedDurationUs(bufferedPositionInLoadingPeriodUs: Int64? = nil) -> Int64 {
        let bufferedPositionInLoadingPeriodUs = bufferedPositionInLoadingPeriodUs ?? playbackInfo.bufferedPositionUs
        guard let loadingPeriodHolder = periodQueue.loading else { return .zero }

        let totalBufferedDurationUs = bufferedPositionInLoadingPeriodUs - loadingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs)
        return max(0, totalBufferedDurationUs)
    }

    private func updateLoadControlTrackSelection(
        mediaPeriodId: MediaPeriodId,
        trackGroups: TrackGroupArray,
        trackSelectorResult: TrackSelectorResult
    ) {
        guard let loadingPeriodHolder = periodQueue.loading else {
            return
        }

        let playbackPositionUs = if loadingPeriodHolder == periodQueue.playing {
            loadingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs)
        } else {
            loadingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs) - loadingPeriodHolder.info.startPositionUs
        }

        let bufferedDurationUs = getTotalBufferedDurationUs(
            bufferedPositionInLoadingPeriodUs: loadingPeriodHolder.getBufferedPositionUs()
        )

        loadControl.onTracksSelected(
            parameters: LoadControlParams(
                playerId: identifier,
                timeline: playbackInfo.timeline,
                mediaPeriodId: mediaPeriodId,
                playbackPositionUs: playbackPositionUs,
                bufferedDurationUs: bufferedDurationUs,
                playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                playWhenReady: playbackInfo.playWhenReady,
                rebuffering: isRebuffering,
                targetLiveOffsetUs: .timeUnset, // TODO: live offset,
                lastRebufferRealtimeMs: lastRebufferRealtimeMs
            ),
            trackGroups: trackGroups,
            trackSelections: trackSelectorResult.selections
        )
    }

    func shouldPlayWhenReady() -> Bool {
        return playbackInfo.playWhenReady && playbackInfo.playbackSuppressionReason == .none
    }

    private func maybeThrowRendererStreamError() throws {
        // TODO: fatalError()
    }

    private func areRenderersPrewarming() -> Bool {
        guard hasSecondaryRenderers else { return false }
        return renderers.first(where: { $0.isPrewarming }) != nil
    }

    private func resolvePositionForPlaylistChange(
        timeline: Timeline,
        playbackInfo: PlaybackInfo,
        pendingInitialSeekPosition: SeekPosition?,
        queue: MediaPeriodQueue,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        window: Window,
        period: Period
    ) -> PositionUpdateForPlaylistChange {
        guard !timeline.isEmpty else {
            return PositionUpdateForPlaylistChange(
                periodId: PlaybackInfo.placeholderMediaPeriodId,
                periodPositionUs: 0,
                requestedContentPositionUs: .timeUnset,
                forceBufferingState: false,
                endPlayback: true,
                setTargetLiveOffset: false
            )
        }

        let oldPeriodId = playbackInfo.periodId
        var newPeriodId = oldPeriodId.periodId
        let isUsingPlaceholderPeriod = isUsingPlaceholderPeriod(playbackInfo: playbackInfo, period: period)
        let oldContentPositionUs = isUsingPlaceholderPeriod ? playbackInfo.requestedContentPositionUs : playbackInfo.positionUs
        var newContentPositionUs = oldContentPositionUs
        var startAtDefaultPositionWindowIndex: Int?
        var forceBufferingState = false
        var endPlayback = false
        var setTargetLiveOffset = false

        if let pendingInitialSeekPosition {
            if let (periodId, periodPositionUs) = resolveSeekPositionUs(
                timeline: timeline,
                seekPosition: pendingInitialSeekPosition,
                trySubsequentPeriods: true,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                window: window,
                period: period
            ) {
                if pendingInitialSeekPosition.windowPositionUs == .timeUnset {
                    startAtDefaultPositionWindowIndex = timeline.periodById(periodId, period: period).windowIndex
                } else {
                    newPeriodId = periodId
                    newContentPositionUs = periodPositionUs
                    setTargetLiveOffset = true
                }
                forceBufferingState = playbackInfo.state == .ended
            } else {
                endPlayback = true
                startAtDefaultPositionWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            }
        } else if playbackInfo.timeline.isEmpty {
            startAtDefaultPositionWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: true)
        } else if timeline.indexOfPeriod(by: newPeriodId) == nil {
            if let newWindowIndex = resolveSubsequentPeriod(
                window: window,
                period: period,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                oldPeriodId: newPeriodId,
                oldTimeline: playbackInfo.timeline,
                newTimeline: timeline
            ) {
                startAtDefaultPositionWindowIndex = newWindowIndex
            } else {
                endPlayback = true
                startAtDefaultPositionWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            }
        } else if oldContentPositionUs == .timeUnset {
            startAtDefaultPositionWindowIndex = timeline.periodById(newPeriodId, period: period).windowIndex
        } else if isUsingPlaceholderPeriod {
            playbackInfo.timeline.periodById(oldPeriodId.periodId, period: period)

            if playbackInfo.timeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex ==
                playbackInfo.timeline.indexOfPeriod(by: oldPeriodId.periodId) {
                let windowPositionUs = oldContentPositionUs + period.positionInWindowUs
                let windowIndex = timeline.periodById(newPeriodId, period: period).windowIndex
                let periodPositionUs = timeline.periodPositionUs(
                    window: window,
                    period: period,
                    windowIndex: windowIndex,
                    windowPositionUs: windowPositionUs
                )

                newPeriodId = periodPositionUs?.0
                newContentPositionUs = periodPositionUs?.1 ?? .zero
            }

            setTargetLiveOffset = true
        }

        var contentPositionForAdResolutionUs = newContentPositionUs
        if let startAtDefaultPositionWindowIndex {
            let defaultPositionUs = timeline.periodPositionUs(
                window: window,
                period: period,
                windowIndex: startAtDefaultPositionWindowIndex,
                windowPositionUs: .timeUnset
            )
            newPeriodId = defaultPositionUs?.0
            contentPositionForAdResolutionUs = defaultPositionUs?.1 ?? newContentPositionUs
            newContentPositionUs = .timeUnset
        }

        // TODO: ad
        let newPeriodUUID = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
            timeline: timeline,
            periodId: newPeriodId,
            positionUs: contentPositionForAdResolutionUs
        )
//        let sameOldAndNewPeriodId = oldPeriodId.periodId == newPeriodId

        return PositionUpdateForPlaylistChange(
            periodId: newPeriodUUID,
            periodPositionUs: contentPositionForAdResolutionUs,
            requestedContentPositionUs: newContentPositionUs,
            forceBufferingState: forceBufferingState,
            endPlayback: endPlayback,
            setTargetLiveOffset: setTargetLiveOffset
        )
    }

    private func isUsingPlaceholderPeriod(playbackInfo: PlaybackInfo, period: Period) -> Bool {
        let periodId = playbackInfo.periodId
        let timeline = playbackInfo.timeline
        return timeline.isEmpty || timeline.periodById(periodId.periodId, period: period).isPlaceholder
    }

    private func updateRebufferingState(isRebuffering: Bool, resetLastRebufferRealtimeMs: Bool) {
        self.isRebuffering = isRebuffering
        self.lastRebufferRealtimeMs = isRebuffering && !resetLastRebufferRealtimeMs ? clock.milliseconds : .timeUnset
    }

    private func resolvePendingMessagePosition(
        pendingMessageInfo: PendingMessageInfo,
        newTimeline: Timeline,
        previousTimeline: Timeline,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        window: Window,
        period: Period
    ) -> Bool {
        if pendingMessageInfo.resolvedPeriodUid == nil {
            let requestPositionUs: Int64 = if pendingMessageInfo.message.positionMs == .endOfSource {
                .timeUnset
            } else {
                Time.msToUs(timeMs: pendingMessageInfo.message.positionMs)
            }

            let periodPosition = resolveSeekPositionUs(
                timeline: newTimeline,
                seekPosition: .init(
                    timeline: pendingMessageInfo.message.timeline,
                    windowIndex: pendingMessageInfo.message.mediaItemIndex,
                    windowPositionUs: requestPositionUs
                ),
                trySubsequentPeriods: false,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                window: window,
                period: period
            )

            guard let periodPosition else { return false }
            pendingMessageInfo.setResolvedPosition(
                periodIndex: newTimeline.indexOfPeriod(by: periodPosition.periodId) ?? -1,
                periodTimeUs: periodPosition.periodPositionUs,
                periodUid: periodPosition.periodId
            )

            if pendingMessageInfo.message.positionMs == .endOfSource {
                resolvePendingMessageEndOfStreamPosition(timeline: newTimeline, messageInfo: pendingMessageInfo, window: window, period: period)
            }
            return true
        }

        guard let resolvedPeriodUid = pendingMessageInfo.resolvedPeriodUid,
              let index = newTimeline.indexOfPeriod(by: resolvedPeriodUid) else {
            return false
        }

        if pendingMessageInfo.message.positionMs == .endOfSource {
            resolvePendingMessageEndOfStreamPosition(timeline: newTimeline, messageInfo: pendingMessageInfo, window: window, period: period)
            return true
        }

        pendingMessageInfo.resolvedPeriodIndex = index
        previousTimeline.periodById(resolvedPeriodUid, period: period)
        if period.isPlaceholder,
           previousTimeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex == previousTimeline.indexOfPeriod(by: resolvedPeriodUid) {
            let windowPositionUs = pendingMessageInfo.resolvedPeriodTimeUs + period.positionInWindowUs
            let windowIndex = newTimeline.periodById(resolvedPeriodUid, period: period).windowIndex
            if let (periodId, periodPositionUs) = newTimeline.periodPositionUs(window: window, period: period, windowIndex: windowIndex, windowPositionUs: windowPositionUs) {
                pendingMessageInfo.setResolvedPosition(
                    periodIndex: newTimeline.indexOfPeriod(by: periodId) ?? -1,
                    periodTimeUs: periodPositionUs,
                    periodUid: periodId
                )
            } else {
                return false
            }
        }

        return true
    }

    private func resolvePendingMessageEndOfStreamPosition(
        timeline: Timeline,
        messageInfo: PendingMessageInfo,
        window: Window,
        period: Period
    ) {
        guard let resolvedPeriodUid = messageInfo.resolvedPeriodUid else {
            assertionFailure()
            return
        }

        let windowIndex = timeline.periodById(resolvedPeriodUid, period: period).windowIndex
        let lastPeriodIndex = timeline.getWindow(windowIndex: windowIndex, window: window).lastPeriodIndex
        let lastPeriodUid = timeline.getPeriod(periodIndex: lastPeriodIndex, period: period, setIds: true).uid

        guard let lastPeriodUid else {
            assertionFailure()
            return
        }

        let positionUs = period.durationUs != .timeUnset ? period.durationUs - 1 : Int64.max
        messageInfo.setResolvedPosition(periodIndex: lastPeriodIndex, periodTimeUs: positionUs, periodUid: lastPeriodUid)
    }

    private func resolveSeekPositionUs(
        timeline: Timeline,
        seekPosition: SeekPosition,
        trySubsequentPeriods: Bool,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        window: Window,
        period: Period
    ) -> (periodId: AnyHashable, periodPositionUs: Int64)? {
        guard !timeline.isEmpty else { return nil }

        let seekTimeline = !seekPosition.timeline.isEmpty ? seekPosition.timeline : timeline
        guard let (periodId, periodPositionUs) = seekTimeline.periodPositionUs(
            window: window,
            period: period,
            windowIndex: seekPosition.windowIndex,
            windowPositionUs: seekPosition.windowPositionUs
        ) else { return nil }

        if timeline.equals(to: seekTimeline) {
            return (periodId, periodPositionUs)
        }

        if timeline.indexOfPeriod(by: periodId) != nil {
            if seekTimeline.periodById(periodId, period: period).isPlaceholder,
               seekTimeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex == seekTimeline.indexOfPeriod(by: periodId) {
                let newWindowIndex = timeline.periodById(periodId, period: period).windowIndex

                return timeline.periodPositionUs(
                    window: window,
                    period: period,
                    windowIndex: newWindowIndex,
                    windowPositionUs: seekPosition.windowPositionUs
                )
            }

            return (periodId, periodPositionUs)
        }

        if trySubsequentPeriods {
            if let newWindowIndex = resolveSubsequentPeriod(
                window: window,
                period: period,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                oldPeriodId: periodId,
                oldTimeline: seekTimeline,
                newTimeline: timeline
            ) {
                return timeline.periodPositionUs(
                    window: window,
                    period: period,
                    windowIndex: newWindowIndex,
                    windowPositionUs: .timeUnset
                )
            }
        }

        return nil
    }

    internal func resolveSubsequentPeriod(
        window: Window,
        period: Period,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        oldPeriodId: AnyHashable,
        oldTimeline: Timeline,
        newTimeline: Timeline
    ) -> Int? {
        let oldWindowIndex = oldTimeline.periodById(oldPeriodId, period: period).windowIndex
        let oldWindowId = oldTimeline.getWindow(windowIndex: oldWindowIndex, window: window).id

        for index in 0..<newTimeline.windowCount() {
            if newTimeline.getWindow(windowIndex: index, window: window).id == oldWindowId {
                return index
            }
        }

        var oldPeriodIndex = oldTimeline.indexOfPeriod(by: oldPeriodId)
        var newPeriodIndex: Int?

        for _ in 0..<oldTimeline.periodCount() {
            if newPeriodIndex == nil {
                if let unwrappedOldPeriodIndex = oldPeriodIndex {
                    oldPeriodIndex = oldTimeline.nextPeriodIndex(
                        periodIndex: unwrappedOldPeriodIndex,
                        period: period,
                        window: window,
                        repeatMode: repeatMode,
                        shuffleModeEnabled: shuffleModeEnabled
                    )

                    if let oldPeriodIndex {
                        newPeriodIndex = newTimeline.indexOfPeriod(by: oldTimeline.id(for: oldPeriodIndex))
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }

        if let newPeriodIndex {
            return newTimeline.getPeriod(periodIndex: newPeriodIndex, period: period).windowIndex
        } else {
            return nil
        }
    }

    private func updatePlayWhenReadyChangeReason(
        playerCommand: PlayerCommand,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason
    ) -> PlayWhenReadyChangeReason {
//        if playerCommand == .doNotPlay {
//            return .audioSessionInterruption
//        }
//
//        if playWhenReadyChangeReason == .audioSessionInterruption {
//            return .userRequest
//        }

        return playWhenReadyChangeReason
    }

    private func updatePlaybackSuppressionReason(
        playerCommand: PlayerCommand,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) -> PlaybackSuppressionReason {
        if playerCommand == .doNotPlay {
            return .audioSessionLoss
        }

        if playbackSuppressionReason == .audioSessionLoss {
            return .none
        }

        // TODO
        return .none
    }
}

extension SEPlayerImplInternal: AudioSessionObserver {
    func executePlayerCommand(_ command: PlayerCommand, isolation: isolated PlayerActor) async {
//        TODO: queue.sync {
//            do {
//                try updatePlayWhenReadyWithAudioFocus(
//                    true,
//                    playerCommand: command,
//                    reason: playbackInfo.playWhenReadyChangeReason,
//                    playbackSuppressionReason: playbackInfo.playbackSuppressionReason,
//                )
//            } catch {
//                handleError(error: error)
//            }
//        }
    }

    func audioDeviceDidChange() {
    }
}

extension SEPlayerImplInternal {
    func setVideoOutput(_ output: VideoSampleBufferRenderer) {
        handler.obtainMessage(what: SEPlayerMessageImpl.setVideoOutput(output)).sendToTarget()
    }

    func removeVideoOutput(_ output: VideoSampleBufferRenderer) {
        handler.obtainMessage(what: SEPlayerMessageImpl.removeVideoOutput(output)).sendToTarget()
    }
}

extension SEPlayerImplInternal {
    struct PlaybackInfoUpdate {
        private(set) var playbackInfo: PlaybackInfo
        private(set) var operationAcks: Int = 0
        private(set) var positionDiscontinuity = false
        private(set) var discontinuityReason: DiscontinuityReason = .autoTransition

        fileprivate private(set) var hasPendingChange: Bool = false

        init(playbackInfo: PlaybackInfo) {
            self.playbackInfo = playbackInfo
        }

        mutating func incrementPendingOperationAcks(_ operationAcks: Int) {
            hasPendingChange = hasPendingChange || operationAcks > 0
            self.operationAcks += operationAcks
        }

        mutating func setPlaybackInfo(_ playbackInfo: PlaybackInfo) {
            hasPendingChange = hasPendingChange || self.playbackInfo != playbackInfo
            self.playbackInfo = playbackInfo
        }

        mutating func setPositionDiscontinuity(_ discontinuityReason: DiscontinuityReason) {
            if positionDiscontinuity, self.discontinuityReason != .internal {
                return
            }
            hasPendingChange = true
            positionDiscontinuity = true
            self.discontinuityReason = discontinuityReason
        }
    }

    private struct SeekPosition {
        let timeline: Timeline
        let windowIndex: Int
        let windowPositionUs: Int64
    }

    private struct PositionUpdateForPlaylistChange {
        let periodId: MediaPeriodId
        let periodPositionUs: Int64
        let requestedContentPositionUs: Int64
        let forceBufferingState: Bool
        let endPlayback: Bool
        let setTargetLiveOffset: Bool
    }

    private final class PendingMessageInfo: Comparable {
        let message: PlayerMessage
        var resolvedPeriodIndex = 0
        var resolvedPeriodTimeUs = Int64.zero
        var resolvedPeriodUid: AnyHashable?

        init(message: PlayerMessage) {
            self.message = message
        }

        func setResolvedPosition(periodIndex: Int, periodTimeUs: Int64, periodUid: AnyHashable) {
            resolvedPeriodIndex = periodIndex
            resolvedPeriodTimeUs = periodTimeUs
            resolvedPeriodUid = periodUid
        }

        static func == (lhs: PendingMessageInfo, rhs: PendingMessageInfo) -> Bool {
            let lhsResolved = lhs.resolvedPeriodUid != nil
            let rhsResolved = rhs.resolvedPeriodUid != nil

            if lhsResolved != rhsResolved { return false }
            if !lhsResolved { return true }

            return lhs.resolvedPeriodIndex == rhs.resolvedPeriodIndex
            && lhs.resolvedPeriodTimeUs == rhs.resolvedPeriodTimeUs
        }

        static func < (lhs: PendingMessageInfo, rhs: PendingMessageInfo) -> Bool {
            let lhsResolved = lhs.resolvedPeriodUid != nil
            let rhsResolved = rhs.resolvedPeriodUid != nil

            if lhsResolved != rhsResolved {
                return lhsResolved && !rhsResolved
            }

            if !lhsResolved {
                return false
            }

            if lhs.resolvedPeriodIndex != rhs.resolvedPeriodIndex {
                return lhs.resolvedPeriodIndex < rhs.resolvedPeriodIndex
            }

            return lhs.resolvedPeriodTimeUs < rhs.resolvedPeriodTimeUs
        }
    }
}
