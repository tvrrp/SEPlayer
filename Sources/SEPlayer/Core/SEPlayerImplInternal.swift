//
//  SEPlayerImplInternal.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMSync
import QuartzCore
import SEPlayerCommon

protocol SEPlayerImplInternalDelegate: AnyObject {
    func onPlaybackInfoUpdate(playbackInfoUpdate: SEPlayerImplInternal.PlaybackInfoUpdate)
}

final class SEPlayerImplInternal: @unchecked Sendable, MediaSourceList.Delegate, MediaPeriodCallback, PlayerMessage.Sender, TrackSelector.InvalidationListener, SERendererDelegate {
    weak var playbackInfoUpdateListener: SEPlayerImplInternalDelegate?

    let identifier: UUID

    var volume: Float {
        get { _volume }
        set {
            _volume = newValue
            post("setVolume") { player in try? player.renderers.forEach { try $0.setVolume(newValue) } }
        }
    }

    var isMuted: Bool {
        get { _isMuted }
        set {
            if _isMuted != newValue {
                post("setAudioIsMuted") { player in try? player.renderers.forEach { try $0.setAudioIsMuted(newValue) } }
            }

            _isMuted = newValue
        }
    }

    let queue: Queue
    let playerActor: PlayerActor
    private let eventTimer: DispatchSourceTimer
    /// Wakes the player at the end of the playing period once its renderers have finished early.
    private let periodEndTimer: DispatchSourceTimer
    private let workQueue: PlayerWorkQueue
    /// The order seeks were asked for in: each takes the next number.
    private var lastSeekSequence = 0 // Guarded by queuedSeekLock.
    /// The numbers of seeks posted and not yet run: a seek older than one of them would only be undone.
    private var queuedSeekSequences: Set<Int> = [] // Guarded by queuedSeekLock.
    private let queuedSeekLock = UnfairLock()
    /// The newest seek that ran or went to wait for the scrubbing seek in flight. A seek waiting for it comes back
    /// later than the seeks asked for meanwhile; it mustn't undo them.
    private var lastStartedSeekSequence = 0
    private let renderers: [RenderersHolder]
    private let rendererCapabilities: [RendererCapabilitiesResolver]
    private var rendererReportedReady: [Bool]
    private let trackSelector: TrackSelector
    private let emptyTrackSelectorResult: TrackSelectorResult
    private let loadControl: LoadControl
    private let bandwidthMeter: BandwidthMeter
    private var window: Window
    private var period: Period
    private let backBufferDuration: CMTime
    private let retainBackBufferFromKeyframe: Bool
    private let mediaClock: DefaultMediaClock
    private let clock: SEClock
    private let livePlaybackSpeedControl: LivePlaybackSpeedControl
    private let outboundTimebase: CMTimebase
    private let periodQueue: MediaPeriodQueue
    private let mediaSourceList: MediaSourceList
    private let hasSecondaryRenderers: Bool

    private var pendingMessages = [PendingMessageInfo]()
    private var _volume: Float = 1.0
    private var _isMuted: Bool = false
    private var playbackInfo: PlaybackInfo
    private var playbackInfoUpdate: PlaybackInfoUpdate
    private var released: Bool = false
    private var pauseAtEndOfWindow: Bool
    private var pendingPauseAtEndOfPeriod: Bool = false
    private var isRebuffering: Bool = false
    private var lastRebufferRealtime: CMTime
    private var shouldContinueLoading: Bool = false
    private var repeatMode: RepeatMode
    private var shuffleModeEnabled: Bool
    private var enabledRendererCount: Int = 0
    private var pendingInitialSeekPosition: SeekPosition?
    private var rendererPosition: CMTime = .zero
    private var rendererPositionElapsedRealtime: CMTime = .zero
    private var nextPendingMessageIndexHint = 0
    private var deliverPendingMessageAtStartPositionRequired = true
    private var pendingRendererRecoveries: [ObjectIdentifier: RendererRecoveryRequest] = [:]
    private var rendererRecoveryBackoffs: [ObjectIdentifier: RendererRecoveryBackoff] = [:]
    /// Renderers whose pending recovery already waited for its delay.
    private var delayedRendererRecoveries: Set<ObjectIdentifier> = []
    /// A renderer error that may pass, while the player selects tracks and seeks again to get past it.
    private var pendingRecoverableRendererError: SEPlaybackError?
    private var rendererRecoveryTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var playbackMaybeBecameStuckAt: CMTime
    private var preloadConfiguration: PreloadConfiguration
    private var lastPreloadPoolInvalidationTimeline: Timeline
    private var prewarmingMediaPeriodDiscontinuity = CMTime.invalid
    private var isPrewarmingDisabledUntilNextTransition: Bool = false
    private var timerIsSuspended: Bool = false
    private var ignoreAudioSinkFlushError = false
    private var seekCompletion: ((Bool) -> Void)? // TODO: clean on different paths
    /// When the seek of ``seekCompletion`` started, for the logs.
    private var seekStartTime: DispatchTime?
    /// A seek waiting for the scrubbing seek in flight to show its frame. Run at once, it would cancel the load of that
    /// frame, and with it the connection bringing it, so a slider that seeks on every change would show no frame until
    /// it stops. Only the latest seek waits; those it replaces count as done, but not finished.
    private var pendingScrubbingSeek: PendingSeek?
    /// Whether the periods were told that seeks only need to show their frame: the last seek came while paused, and
    /// could land near its position.
    private var isScrubbing = false
    /// The user scrubs: paused seeks only need their frame, exact ones too.
    private var scrubbingModeEnabled = false

    init(
        queue: Queue,
        renderers: [SERenderer],
        trackSelector: TrackSelector,
        emptyTrackSelectorResult: TrackSelectorResult,
        loadControl: LoadControl,
        bandwidthMeter: BandwidthMeter,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        pauseAtEndOfWindow: Bool,
        clock: SEClock,
        outboundTimebase: CMTimebase,
        mediaClock: DefaultMediaClock,
        identifier: UUID,
        preloadConfiguration: PreloadConfiguration,
        livePlaybackSpeedControl: LivePlaybackSpeedControl? = nil
    ) throws {
        self.queue = queue
        self.playerActor = queue.playerActor()
        eventTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        periodEndTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        workQueue = PlayerWorkQueue(scheduler: clock.makeScheduler(queue: queue))
        self.identifier = identifier
        self.trackSelector = trackSelector
        self.emptyTrackSelectorResult = emptyTrackSelectorResult
        self.loadControl = loadControl
        self.bandwidthMeter = bandwidthMeter
        self.repeatMode = repeatMode
        self.shuffleModeEnabled = shuffleModeEnabled
        self.pauseAtEndOfWindow = pauseAtEndOfWindow
        self.clock = clock
        self.livePlaybackSpeedControl = livePlaybackSpeedControl ?? DefaultLivePlaybackSpeedControl(clock: clock)
        self.outboundTimebase = outboundTimebase
        self.mediaClock = mediaClock
        self.preloadConfiguration = preloadConfiguration

        playbackMaybeBecameStuckAt = .invalid
        lastRebufferRealtime = .invalid
        backBufferDuration = loadControl.getBackBufferDuration(playerId: identifier)
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
        periodQueue = MediaPeriodQueue(mediaPeriodBuilder: { info, rendererPositionOffset in
            try! MediaPeriodHolder(
                queue: queue,
                rendererCapabilities: renderers.map { $0.getCapabilities() },
                rendererPositionOffset: rendererPositionOffset,
                trackSelector: trackSelector,
                allocator: loadControl.getAllocator(),
                mediaSourceList: mediaSourceList,
                info: info,
                emptyTrackSelectorResult: emptyTrackSelectorResult,
                targetPreloadBufferDuration: preloadConfiguration.targetPreloadDuration
            )
        })

        mediaSourceList.delegate = self
        workQueue.onUpdate = { [weak self] in self?.runUpdate() }
        trackSelector.initialize(listener: self, bandwidthMeter: bandwidthMeter)
        // Starts following the app in and out of the background, which decides how renderer failures are taken.
        _ = ApplicationActivity.shared

        eventTimer.setEventHandler { [weak self] in
            self?.requestPeriodsUpdate()
        }
        eventTimer.resume()

        periodEndTimer.setEventHandler { [weak self] in
            self?.workQueue.requestUpdate()
        }
        periodEndTimer.resume()

        mediaClock.onRendererClockCaughtUp = { [weak self] in
            self?.workQueue.requestUpdate()
        }
        // Called on the player queue while the clock syncs.
        mediaClock.onRendererTimeSourceChanged = { [weak self] source in
            self?.setRendererTimeSource(source)
        }
    }

    private func setRendererTimeSource(_ source: RendererTimeSource) {
        do {
            try renderers.forEach { try $0.setTimeSource(source) }
        } catch {
            SELogger.error(.sync, "Renderers can't follow the new time source: \(error)")
        }
    }

    nonisolated func prepare() {
        post("prepare") { try $0.prepareInternal() }
    }

    nonisolated func setPlayWhenReady(
        _ playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) {
        post("playWhenReady(\(playWhenReady))") {
            try $0.setPlayWhenReadyInternal(
                playWhenReady,
                playbackSuppressionReason: playbackSuppressionReason,
                operationAck: true,
                playWhenReadyChangeReason: playWhenReadyChangeReason
            )
        }
    }

    nonisolated func setScrubbingModeEnabled(_ isEnabled: Bool) {
        // The next seek follows it: one the user lets go with loads media to play.
        post("setScrubbingModeEnabled(\(isEnabled))") { $0.scrubbingModeEnabled = isEnabled }
    }

    nonisolated func setPauseAtEndOfWindow(_ pauseAtEndOfWindow: Bool) {
        post("setPauseAtEndOfWindow") { try $0.setPauseAtEndOfWindowInternal(pauseAtEndOfWindow) }
    }

    nonisolated func setRepeatMode(_ repeatMode: RepeatMode) {
        post("setRepeatMode") { try $0.setRepeatModeInternal(repeatMode) }
    }

    nonisolated func setShuffleModeEnabled(_ shuffleModeEnabled: Bool) {
        post("setShuffleEnabled") { try $0.setShuffleModeEnabledInternal(shuffleModeEnabled) }
    }

    nonisolated func setPreloadConfiguration(_ preloadConfiguration: PreloadConfiguration) {
        post("setPreloadConfiguration") { try $0.setPreloadConfigurationInternal(preloadConfiguration) }
    }

    nonisolated func seekTo(
        timeline: Timeline,
        windowIndex: Int,
        position: CMTime,
        seekParameters: SeekParameters,
        completion: ((Bool) -> Void)?
    ) {
        let sequence = queuedSeekLock.withLock {
            lastSeekSequence += 1
            return lastSeekSequence
        }
        postSeek(PendingSeek(
            timeline: timeline,
            windowIndex: windowIndex,
            position: position,
            seekParameters: seekParameters,
            sequence: sequence,
            completion: completion
        ))
    }

    nonisolated func setPlaybackParameters(_ playbackParameters: PlaybackParameters) {
        post("setPlaybackParameters") { try $0.setPlaybackParametersInternal(playbackParameters) }
    }

    nonisolated func stop() {
        post("stop") { $0.stopInternal(forceResetRenderers: false, acknowledgeStop: true) }
    }

    nonisolated func setMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        windowIndex: Int?,
        position: CMTime,
        shuffleOrder: ShuffleOrder
    ) {
        post("setMediaSources") {
            try $0.setMediaSourcesInternal(
                mediaSources,
                windowIndex: windowIndex,
                position: position,
                shuffleOrder: shuffleOrder
            )
        }
    }

    nonisolated func insertMediaSources(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        at index: Int,
        shuffleOrder: ShuffleOrder
    ) {
        post("addMediaSources") { try $0.insertMediaSourcesInternal(mediaSources, at: index, shuffleOrder: shuffleOrder) }
    }

    nonisolated func removeMediaSources(range: Range<Int>, shuffleOrder: ShuffleOrder) {
        post("removeMediaSources") { $0.removeMediaSourcesInternal(range: range, shuffleOrder: shuffleOrder) }
    }

    nonisolated func moveMediaSources(range: Range<Int>, to newIndex: Int, shuffleOrder: ShuffleOrder) {
        post("moveMediaSources") { $0.moveMediaSourcesInternal(range: range, to: newIndex, shuffleOrder: shuffleOrder) }
    }

    nonisolated func setShuffleOrder(_ shuffleOrder: ShuffleOrder) {
        post("setShuffleOrder") { $0.setShuffleOrderInternal(shuffleOrder) }
    }

    nonisolated func updateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) {
        post("updateMediaSourcesWithMediaItems") { try $0.updateMediaSourcesInternal(with: mediaItems, range: range) }
    }

    nonisolated func sendMessage(_ message: PlayerMessage) {
        // TODO: check for release
        post("sendMessage") { try $0.sendMessageInternal(message) }
    }

    nonisolated func release() async {
        await withCheckedContinuation { continuation in
            // Outside `perform`: nothing is published after the release.
            workQueue.post { [weak self] in
                SELogger.verbose(.scheduling, "Runs release")
                self?.releaseInternal(continuation: continuation)
            }
        }
    }

    func playlistUpdateRequested() {
        // The update runs after the new timeline, not before with the old one.
        workQueue.cancelPendingUpdates()
        post("playlistUpdateRequested") { try $0.mediaSourceListUpdateRequestedInternal() }
    }

    func didPrepare(mediaPeriod: any MediaPeriod) {
        post("periodPrepared(\(type(of: mediaPeriod)))") { try $0.handlePeriodPrepared(mediaPeriod: mediaPeriod) }
    }

    /// Sent when a load completes, is cancelled, or is retried. After a seek cancels the running
    /// load, this is what starts the next one.
    func continueLoadingRequested(with source: any MediaPeriod) {
        post("sourceContinueLoadingRequested(\(type(of: source)))") {
            try $0.handleContinueLoadingRequested(mediaPeriod: source)
        }
    }

    func onTrackSelectionsInvalidated(application: TrackSelectionApplication) {
        post("trackSelectionInvalidated(\(application))") { player in
            // Nothing updates the position while media plays: the selection applies from where playback is now.
            try player.updatePlaybackPositionsInternal()
            switch application {
            case .deferred:
                try player.reselectTracksForFutureLoads()
            case .immediate:
                try player.reselectTracksPreservingDisplayedImage()
            }
        }
    }

    func onRendererCapabilitiesChanged(_ renderer: SERenderer) {
        post("rendererCapabilitiesChanged") { try $0.reselectTracksInternalAndSeek() }
    }

    // MARK: - Running work

    /// Runs `work` after the work posted before it, as one piece of the player's work.
    ///
    /// - Parameter name: What the work does, for the trace of the player's work.
    private func post(_ name: @autoclosure @escaping () -> String, _ work: @escaping (SEPlayerImplInternal) throws -> Void) {
        workQueue.post { [weak self] in
            guard let self else { return }
            perform(name()) { try work(self) }
        }
    }

    /// Runs `work` ahead of any work posted that hasn't started yet.
    private func postUrgent(_ name: @autoclosure @escaping () -> String, _ work: @escaping (SEPlayerImplInternal) throws -> Void) {
        workQueue.postUrgent { [weak self] in
            guard let self else { return }
            perform(name()) { try work(self) }
        }
    }

    /// Runs `work` once `delay` has passed, as one piece of the player's work, unless the returned item is cancelled
    /// first.
    @discardableResult
    private func post(
        _ name: @autoclosure @escaping () -> String,
        after delay: DispatchTimeInterval,
        _ work: @escaping (SEPlayerImplInternal) throws -> Void
    ) -> DispatchWorkItem {
        workQueue.post(after: delay) { [weak self] in
            guard let self else { return }
            perform(name()) { try work(self) }
        }
    }

    /// Runs one piece of the player's work. An error stops playback, or tries to get past it, and what the work changed
    /// is published after.
    private func perform(_ name: @autoclosure () -> String, _ body: () throws -> Void) {
        SELogger.verbose(.scheduling, "Runs \(name())")
        do {
            try body()
        } catch {
            handleError(error)
        }
        maybeNotifyPlaybackInfoChanged()
    }

    /// The periodic update: what the renderers and the periods do next.
    private func runUpdate() {
        perform("doSomeWork") { try doSomeWork() }
    }

    /// Updates the periods: what loads, what the renderers read, what plays.
    private func requestPeriodsUpdate() {
        post("maybeUpdatePeriods") { try $0.updatePeriods() }
    }

    /// Posts the seek, recorded until it runs: a seek older than one posted behind it would only be undone.
    private func postSeek(_ seek: PendingSeek) {
        queuedSeekLock.withLock { _ = queuedSeekSequences.insert(seek.sequence) }
        post("seekTo(\(seek.windowIndex), \(seek.position.seconds))") { player in
            player.queuedSeekLock.withLock { _ = player.queuedSeekSequences.remove(seek.sequence) }
            try player.runSeek(seek)
        }
    }

    /// Whether a seek asked for after this one is posted, or ran already. A seek that waited for the scrubbing seek in
    /// flight is posted again once that one is done, possibly behind newer ones.
    private func isSuperseded(_ seek: PendingSeek) -> Bool {
        let newestQueued = queuedSeekLock.withLock { queuedSeekSequences.max() ?? 0 }
        return seek.sequence < max(newestQueued, lastStartedSeekSequence)
    }

    private func runSeek(_ seek: PendingSeek) throws {
        if isSuperseded(seek) {
            // A later seek is queued, or ran: this one would only be undone. It counts as done, but not finished.
            SELogger.debug(.seek, "Skipping the seek to \(seek.position.seconds): a later one is queued or ran")
            playbackInfoUpdate.incrementPendingOperationAcks(1)
            seek.completion?(false)
        } else if waitsForScrubbingSeek() {
            lastStartedSeekSequence = seek.sequence
            if let replaced = pendingScrubbingSeek {
                playbackInfoUpdate.incrementPendingOperationAcks(1)
                replaced.completion?(false)
            }
            SELogger.debug(.seek, "The seek to \(seek.position.seconds) waits for the frame of the scrubbing seek in flight")
            pendingScrubbingSeek = seek
        } else {
            lastStartedSeekSequence = seek.sequence
            try seekToInternal(
                seekPosition: .init(
                    timeline: seek.timeline,
                    windowIndex: seek.windowIndex,
                    windowPosition: seek.position
                ),
                incrementAcks: true,
                seekParameters: seek.seekParameters,
                completion: seek.completion
            )
        }
    }

    /// Stops playback with the error, or tries once to get past a renderer error that may pass.
    ///
    /// An error of the source keeps the renderers: preparing again goes on from them. An error of a renderer, or an
    /// unexpected one, resets them too.
    private func handleError(_ error: Error) {
        var playbackError = SEPlaybackError.create(from: error)

        if case .renderer = playbackError.type, let reading = periodQueue.reading {
            // Renderers fail on what they read, which can be a period ahead of the one that plays.
            playbackError = playbackError.copy(with: reading.info.id)
        }

        if playbackError.isRecoverable, pendingRecoverableRendererError == nil {
            SELogger.warning(.recovery, "Recoverable renderer error, retrying: \(playbackError)")
            pendingRecoverableRendererError = playbackError
            // Ahead of the other work: it would go on with the renderer that failed.
            postUrgent("attemptRendererErrorRecovery") { try $0.reselectTracksInternalAndSeek() }
            return
        }

        SELogger.error(.playback, "Playback failed: \(playbackError)")
        if let pendingRecoverableRendererError {
            SELogger.error(.recovery, "Recovery from \(pendingRecoverableRendererError) failed")
            self.pendingRecoverableRendererError = nil
        }

        switch playbackError.type {
        case .renderer:
            // The error is reported at the period the renderer read, so playback moves there.
            if periodQueue.playing !== periodQueue.reading {
                while periodQueue.playing !== periodQueue.reading, periodQueue.advancePlayingPeriod() != nil {}
                if let playing = periodQueue.playing {
                    maybeNotifyPlaybackInfoChanged()
                    playbackInfo = handlePositionDiscontinuity(
                        mediaPeriodId: playing.info.id,
                        position: playing.info.startPosition,
                        requestedContentPosition: playing.info.requestedContentPosition,
                        discontinuityStartPosition: playing.info.startPosition,
                        reportDiscontinuity: true,
                        discontinuityReason: .autoTransition
                    )
                }
            }
            stopInternal(forceResetRenderers: true, acknowledgeStop: false)
        case .mediaSource:
            // Only the playing period's errors are thrown.
            if let playing = periodQueue.playing {
                playbackError = playbackError.copy(with: playing.info.id)
            }
            stopInternal(forceResetRenderers: false, acknowledgeStop: false)
        case .unexpected, .remote:
            stopInternal(forceResetRenderers: true, acknowledgeStop: false)
        }
        playbackInfo = playbackInfo.setPlaybackError(playbackError)
    }

    private func setState(_ state: PlayerState) {
        assert(queue.isCurrent())
        guard playbackInfo.state != state else { return }
        if state != .buffering {
            playbackMaybeBecameStuckAt = .invalid
        }
        SELogger.info(.playback, "State \(playbackInfo.state) → \(state) at \(playbackInfo.position.seconds)")
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
        resetInternal(
            resetRenderers: false,
            resetPosition: false,
            releaseMediaSourceList: false,
            resetError: true
        )
        loadControl.onPrepared(playerId: identifier)
        setState(playbackInfo.timeline.isEmpty ? .ended : .buffering)
        try! mediaSourceList.prepare(mediaTransferListener: bandwidthMeter.transferListener)
        try mediaClock.getTimebase().addTimer(eventTimer)
        try mediaClock.getTimebase().addTimer(periodEndTimer)
        setRendererTimeSource(mediaClock.getRendererTimeSource())
        try outboundTimebase.setRate(to: 1.0)
        workQueue.requestUpdate()
    }

    private func setMediaSourcesInternal(
        _ mediaSources: [MediaSourceList.MediaSourceHolder],
        windowIndex: Int?,
        position: CMTime,
        shuffleOrder: ShuffleOrder
    ) throws {
        assert(queue.isCurrent())
        playbackInfoUpdate.incrementPendingOperationAcks(1)
        if let windowIndex {
            pendingInitialSeekPosition = SeekPosition(
                timeline: PlaylistTimeline(mediaSourceInfoHolders: mediaSources, shuffleOrder: shuffleOrder),
                windowIndex: windowIndex,
                windowPosition: position
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
        SELogger.info(.playback, "Play when ready \(playWhenReady), reason \(playWhenReadyChangeReason), suppression \(playbackSuppressionReason)")
        playbackInfoUpdate.incrementPendingOperationAcks(operationAck ? 1 : 0)
        if playWhenReady, isScrubbing {
            // What scrubbing loaded only shows a frame: playback loads from the position again.
            setScrubbing(false)
            try seekToCurrentPosition(sendDiscontinuity: false, forceDisableRenderers: false)
        }
        try updatePlayWhenReady(
            playWhenReady,
            reason: playWhenReadyChangeReason,
            playbackSuppressionReason: playbackSuppressionReason
        )
    }

    /// Updates the playback info with whether to play, and starts or stops the renderers for it.
    ///
    /// - Parameter playbackSuppressionReason: Why playback waits although it should play, as the audio session says.
    private func updatePlayWhenReady(
        _ playWhenReady: Bool,
        reason playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) throws {
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

        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtime: false)
        notifyTrackSelectionPlayWhenReadyChanged(playWhenReady)
        if !shouldPlayWhenReady() {
            stopRenderers()
            try! updatePlaybackPositionsInternal()
            periodQueue.reevaluateBuffer(rendererPosition: rendererPosition)
        } else {
            if playbackInfo.state == .ready {
                mediaClock.start()
                try! startRenderers()
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

    private func seekToCurrentPosition(
        sendDiscontinuity: Bool,
        forceDisableRenderers: Bool = true,
        preserveDisplayedImage: Bool = false,
        periodPosition: CMTime? = nil
    ) throws {
        guard let playingPeriod = periodQueue.playing else {
            return
        }

        let outputs = renderers.flatMap { [$0.primaryRenderer, $0.secondaryRenderer].compactMap { $0 } }
        if preserveDisplayedImage {
            try outputs.forEach { try $0.handleMessage(.setPreservesDisplayedImageOnDisable(true)) }
        }
        defer {
            if preserveDisplayedImage {
                outputs.forEach { try? $0.handleMessage(.setPreservesDisplayedImageOnDisable(false)) }
            }
        }
        let periodId = playingPeriod.info.id
        let newPosition = try seekToPeriodPosition(
            periodId: periodId,
            periodPosition: periodPosition ?? playbackInfo.position,
            forceDisableRenderers: forceDisableRenderers,
            forceBufferingState: false,
            isRecoverySeek: preserveDisplayedImage
        )

        if newPosition != playbackInfo.position {
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: periodId,
                position: newPosition,
                requestedContentPosition: playbackInfo.requestedContentPosition,
                discontinuityStartPosition: playbackInfo.discontinuityStartPosition,
                reportDiscontinuity: sendDiscontinuity,
                discontinuityReason: .internal
            )
        }
    }

    private func startRenderers() throws {
        SELogger.debug(.lifecycle, "Starting renderers at \(rendererPosition.seconds)")
        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }
        let trackSelectorResult = playingPeriodHolder.trackSelectorResults
        for index in 0..<renderers.count {
            if !trackSelectorResult.isRendererEnabled(for: index) {
                continue
            }

            try renderers[index].start()
        }
    }

    private func stopRenderers() {
        mediaClock.stop()
        renderers.forEach { $0.stop() }
    }

    func rendererNeedsRecovery(_ renderer: any SERenderer, request: RendererRecoveryRequest) {
        let name = "rendererNeedsRecovery(\(type(of: renderer)), \(request.reason))"
        post(name) { [weak renderer] player in
            guard let renderer, player.canRecover(renderer, with: request) else {
                return
            }

            let key = ObjectIdentifier(renderer)
            let pendingRequest = player.pendingRendererRecoveries[key]
            if let pendingRequest, pendingRequest.context == request.context {
                // A request for the same failure that is at least as severe is already waiting.
                guard pendingRequest.reason.rawValue < request.reason.rawValue else {
                    return
                }
            }

            player.pendingRendererRecoveries[key] = request
            if pendingRequest == nil {
                player.postRecovery(of: renderer)
            }
        }
    }

    /// Whether `request` still applies: the renderer wasn't disabled or reset since it failed.
    private func canRecover(_ renderer: any SERenderer, with request: RendererRecoveryRequest) -> Bool {
        !released
            && renderer.getState() != .disabled
            && renderer.getRecoveryContext() == request.context
    }

    private func postRecovery(of renderer: any SERenderer) {
        post("recoverRenderer(\(type(of: renderer)))") { try $0.recoverRenderer(renderer) }
    }

    /// Recovers `renderer` from a failure of its output, without failing playback.
    ///
    /// The renderer is flushed in place if the failure allows it. Otherwise all tracks are rebuffered from the
    /// current position. Rebuffers that follow each other closely are delayed, longer each time.
    private func recoverRenderer(_ renderer: any SERenderer) throws {
        let key = ObjectIdentifier(renderer)
        guard let request = pendingRendererRecoveries.removeValue(forKey: key) else {
            return
        }
        guard canRecover(renderer, with: request), let playingPeriod = periodQueue.playing else {
            return
        }

        // A recovery that already waited for its delay goes straight to the rebuffer.
        let wasDelayed = delayedRendererRecoveries.remove(key) != nil

        try updatePlaybackPositionsInternal()
        guard renderer.getRecoveryContext() == request.context else { return }

        let position = mediaClock.getPosition()
        let isPlayingRenderer = isReadingPlayingPeriod(renderer, request: request, playingPeriod: playingPeriod)
        let canFlushInPlace = [.automaticFlush, .decoderRequiresFlush, .outputFailed].contains(request.reason)
        var hasTriedFlush = false

        if !wasDelayed, isPlayingRenderer, canFlushInPlace {
            hasTriedFlush = true
            if flushInPlace(renderer, at: position, reason: request.reason) {
                workQueue.requestUpdate()
                return
            }
        }

        if !wasDelayed, delayRebufferIfNeeded(for: renderer, request: request) {
            return
        }

        // An output that failed, or that the system reset, is rebuilt before it prerolls again.
        let mustRebuildOutput = request.reason == .mediaServicesWereReset
            || (request.reason == .outputFailed && !hasTriedFlush)
        if mustRebuildOutput {
            do {
                _ = try renderer.recoverOutput(at: position, reason: request.reason)
            } catch {
                SELogger.warning(.recovery, "Rebuilding the output of \(type(of: renderer)) failed: \(error)")
            }
        }

        let restartPosition = isPlayingRenderer
            ? rebufferPosition(for: request, playingPeriod: playingPeriod)
            : nil
        let rebufferStart = (restartPosition ?? playbackInfo.position).seconds
        SELogger.info(.recovery, "\(type(of: renderer)) recovers from \(request.reason): rebuffering from \(rebufferStart)")

        try seekToCurrentPosition(
            sendDiscontinuity: true,
            forceDisableRenderers: !isPlayingRenderer || periodQueue.reading !== playingPeriod,
            preserveDisplayedImage: true,
            periodPosition: restartPosition
        )
        startRecoveryTimeout(for: renderer, request: request)
    }

    /// Whether `renderer` reads a stream of the playing period. Reading can already be in the next period, and only
    /// the playing period can be rewound.
    private func isReadingPlayingPeriod(
        _ renderer: any SERenderer,
        request: RendererRecoveryRequest,
        playingPeriod: MediaPeriodHolder
    ) -> Bool {
        guard request.context.mediaPeriodId == playingPeriod.info.id else {
            return false
        }
        guard let rendererStream = renderer.getStream() else {
            return false
        }

        return playingPeriod.sampleStreams.contains { stream in
            stream.map(rendererStream.isEqual(to:)) ?? false
        }
    }

    /// - Returns: Whether the renderer recovered.
    private func flushInPlace(_ renderer: any SERenderer, at position: CMTime, reason: RendererRecoveryReason) -> Bool {
        do {
            return try renderer.recoverOutput(at: position, reason: reason)
        } catch {
            SELogger.warning(.recovery, "Flushing \(type(of: renderer)) failed, rebuffering instead: \(error)")
            return false
        }
    }

    /// Delays the rebuffer when the renderer was rebuffered recently.
    ///
    /// - Returns: Whether the recovery was scheduled for later.
    private func delayRebufferIfNeeded(for renderer: any SERenderer, request: RendererRecoveryRequest) -> Bool {
        // A rate change can flush the output every time, so automatic flushes are never delayed.
        guard request.reason != .automaticFlush else {
            return false
        }

        let key = ObjectIdentifier(renderer)
        var backoff = rendererRecoveryBackoffs[key] ?? RendererRecoveryBackoff()
        let delay = backoff.delay()
        rendererRecoveryBackoffs[key] = backoff
        guard delay.totalMilliseconds > 0 else {
            return false
        }

        SELogger.info(.recovery, "Rebuffering for \(type(of: renderer)) in \(delay.totalMilliseconds)ms: it recovered just before")
        post("delayedRecovery(\(type(of: renderer)))", after: delay) { [weak renderer] player in
            guard let renderer, player.canRecover(renderer, with: request) else {
                return
            }
            // Another recovery of the renderer was requested meanwhile.
            guard player.pendingRendererRecoveries[key] == nil else {
                return
            }

            player.delayedRendererRecoveries.insert(key)
            player.pendingRendererRecoveries[key] = request
            player.postRecovery(of: renderer)
        }

        return true
    }

    /// The period position of the first sample the renderer flushed. The timebase kept running past it, so the
    /// media between it and the playhead was never played.
    private func rebufferPosition(for request: RendererRecoveryRequest, playingPeriod: MediaPeriodHolder) -> CMTime? {
        guard request.position.isNumeric else {
            return nil
        }

        let flushPosition = playingPeriod.toPeriodTime(rendererTime: request.position)
        guard flushPosition >= playingPeriod.info.startPosition, flushPosition < playbackInfo.position else {
            return nil
        }

        return flushPosition
    }

    /// Requests another recovery if the renderer still isn't ready a while after the rebuffer although its media
    /// is: its output failed again. While the media is still loading, the timeout starts over.
    private func startRecoveryTimeout(for renderer: any SERenderer, request: RendererRecoveryRequest) {
        let key = ObjectIdentifier(renderer)
        let context = renderer.getRecoveryContext()
        let timeout = Self.rendererRecoveryTimeout

        rendererRecoveryTimeouts[key]?.cancel()
        rendererRecoveryTimeouts[key] = post(
            "rendererRecoveryTimeout(\(type(of: renderer)))",
            after: timeout
        ) { [weak renderer] player in
            guard let renderer, !player.released, renderer.getRecoveryContext() == context else {
                return
            }
            guard player.playbackInfo.state == .buffering else {
                return
            }

            let isMediaReady = renderer.getStream()?.isReady() == true
            guard !renderer.isReady(), isMediaReady else {
                player.startRecoveryTimeout(for: renderer, request: request)
                return
            }

            SELogger.warning(.recovery, "\(type(of: renderer)) isn't ready after rebuffering, though its media is: recovering again")
            let newRequest = RendererRecoveryRequest(
                reason: .recoveryTimedOut,
                context: context,
                underlyingError: request.underlyingError
            )
            player.rendererNeedsRecovery(renderer, request: newRequest)
        }
    }

    private func cancelRecoveryTimeouts() {
        rendererRecoveryTimeouts.values.forEach { $0.cancel() }
        rendererRecoveryTimeouts.removeAll()
    }

    func rendererFinishedPreroll(_ renderer: any SERenderer) {
        SELogger.debug(.lifecycle, "\(type(of: renderer)) finished its preroll")
        workQueue.requestUpdate()
    }

    func rendererDidPresentOutput(_ renderer: any SERenderer) {
        // A paused seek may be done.
        workQueue.requestUpdate()
    }

    func rendererDidStartPlayback(_ renderer: any SERenderer) {
        // The startup time ends here: the clock moves and media plays. TODO: report it to analytics.
        SELogger.info(.playback, "Playback started at \(mediaClock.getPosition().seconds)")
    }

    func rendererPipelineStalled(_ renderer: any SERenderer) {
        SELogger.info(.lifecycle, "\(type(of: renderer)) stalled: its output ran dry")
        workQueue.requestUpdate()
    }

    func rendererDidFinishReading(_ renderer: any SERenderer) {
        SELogger.debug(.lifecycle, "\(type(of: renderer)) read its stream to the end")
        workQueue.requestUpdate()
    }

    @objc
    func rendererDidReadSampleAtBoundaries(notification: Notification) {
        workQueue.requestUpdate()
    }

    func rendererDidFinishRendering(_ renderer: any SERenderer) {
        workQueue.requestUpdate()
    }

    func onRendererError(_ renderer: any SERenderer, error: SEPlaybackError) {
        // Compatibility for renderers using the older flush-required error contract.
        if error.isRecoverable, case .renderer(.rendererRequiresFlush) = error.type {
            rendererNeedsRecovery(renderer, request: .init(
                reason: .decoderRequiresFlush,
                context: renderer.getRecoveryContext(),
                underlyingError: error.underlyingError
            ))
            return
        }
        let context = renderer.getRecoveryContext()
        postUrgent("rendererFailure(\(type(of: renderer)))") { _ in
            // A renderer reset or disabled since doesn't fail playback any more.
            if renderer.getState() != .disabled, renderer.getRecoveryContext() == context { throw error }
        }
    }

    private func updatePlaybackPositionsInternal() throws {
        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }

        let discontinuityPosition = playingPeriodHolder.isPrepared
            ? playingPeriodHolder.mediaPeriod.readDiscontinuity()
            : .invalid

        if discontinuityPosition.isNumeric {
            if !playingPeriodHolder.isFullyBuffered() {
                periodQueue.removeAfter(mediaPeriodHolder: playingPeriodHolder)
                handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                try maybeContinueLoading()
            }
            try! resetRendererPosition(periodPosition: discontinuityPosition)
            if discontinuityPosition != playbackInfo.position {
                playbackInfo = handlePositionDiscontinuity(
                    mediaPeriodId: playbackInfo.periodId,
                    position: discontinuityPosition,
                    requestedContentPosition: playbackInfo.requestedContentPosition,
                    discontinuityStartPosition: discontinuityPosition,
                    reportDiscontinuity: true,
                    discontinuityReason: .internal
                )
            }
        } else {
            rendererPosition = mediaClock
                .syncAndGetPosition(isReadingAhead: playingPeriodHolder !== periodQueue.reading)
            var periodPosition = playingPeriodHolder.toPeriodTime(rendererTime: rendererPosition)


            if playingPeriodHolder.info.duration.isValid {
                periodPosition = periodPosition.convertScale(
                    playingPeriodHolder.info.duration.timescale,
                    method: .roundTowardZero
                )
            }

            try maybeTriggerPendingMessages(oldPeriodPosition: playbackInfo.position, newPeriodPosition: periodPosition)
            playbackInfo = playbackInfo.setPosition(periodPosition)
        }

        if let loading = periodQueue.loading {
            playbackInfo.bufferedPosition = loading.getBufferedPosition()
            playbackInfo.totalBufferedDuration = getReportedTotalBufferedDuration()
        }

        // Live playback speeds up or slows down to keep its offset from the live edge.
        if playbackInfo.playWhenReady, playbackInfo.state == .ready,
           shouldUseLivePlaybackSpeedControl(timeline: playbackInfo.timeline, periodId: playbackInfo.periodId),
           playbackInfo.playbackParameters.playbackRate == 1 {
            let adjustedSpeed = livePlaybackSpeedControl.adjustedPlaybackSpeed(
                liveOffset: getCurrentLiveOffset(),
                bufferedDuration: getTotalBufferedDuration()
            )
            if mediaClock.getPlaybackParameters().playbackRate != adjustedSpeed {
                var adjustedParameters = playbackInfo.playbackParameters
                adjustedParameters.newSpeed(adjustedSpeed)
                try setMediaClockPlaybackParameters(playbackParameters: adjustedParameters)
                try handlePlaybackParameters(
                    playbackParameters: playbackInfo.playbackParameters,
                    currentPlaybackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                    updatePlaybackInfo: false,
                    acknowledgeCommand: false
                )
            }
        }
    }

    private func setMediaClockPlaybackParameters(playbackParameters: PlaybackParameters) throws {
        try mediaClock.setPlaybackParameters(new: playbackParameters)
    }

    private func notifyTrackSelectionRebuffer() {
        // TODO: notifyTrackSelectionRebuffer
    }

    private func doSomeWork() throws {
        assert(queue.isCurrent())
        // Errors of loads that retry, and playback stuck buffering, show only to a player that looks again.
        defer { scheduleBufferingWork() }

        try updatePeriods()

        // The scrubbing seek in flight took too long: the seek waiting for it runs, and cancels it.
        if pendingScrubbingSeek != nil, !waitsForScrubbingSeek() {
            runPendingScrubbingSeek()
        }

        if playbackInfo.state == .idle || playbackInfo.state == .ended {
            return
        }

        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }

        try updatePlaybackPositionsInternal()

        var renderersEnded = true
        var renderersAllowPlayback = true

        if playingPeriodHolder.isPrepared {
            rendererPositionElapsedRealtime = clock.time
            try playingPeriodHolder.mediaPeriod.discardBuffer(
                position: playbackInfo.position - backBufferDuration,
                toKeyframe: retainBackBufferFromKeyframe
            )

            for (index, renderer) in renderers.enumerated() {
                if renderer.enabledRendererCount == 0 {
                    maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: false)
                    continue
                }

                try renderer.render(
                    rendererPosition: rendererPosition,
                    rendererPositionElapsedRealtime: rendererPositionElapsedRealtime
                )
                renderersEnded = renderersEnded && renderer.isEnded
                let allowsPlayback = renderer.allowsPlayback(playingPeriodHolder: playingPeriodHolder)
                maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: allowsPlayback)
                renderersAllowPlayback = renderersAllowPlayback && allowsPlayback
                if !allowsPlayback {
                    try maybeThrowRendererStreamError(rendererIndex: index)
                }
            }
        } else {
            try playingPeriodHolder.mediaPeriod.maybeThrowPrepareError()
        }
        try maybeThrowLoadingPeriodPrepareError()
        maybeCompleteSeek(playingPeriodHolder: playingPeriodHolder, renderersAllowPlayback: renderersAllowPlayback)

        let playingPeriodDuration = playingPeriodHolder.info.duration
        let finishedRendering = renderersEnded
            && playingPeriodHolder.isPrepared
            && (playingPeriodDuration.isValid == false || playingPeriodDuration <= playbackInfo.position)

        // The renderers have played out all of their media, but the period goes on: its last sample
        // can end before the period does. The player has no timer of its own, so nothing would
        // look again once the period ends.
        let timebase = mediaClock.getTimebase()
        if renderersEnded, playingPeriodHolder.isPrepared, !finishedRendering, playingPeriodDuration.isNumeric {
            try? timebase.setTimerNextFireTime(
                periodEndTimer,
                fireTime: playingPeriodHolder.toRendererTime(periodTime: playingPeriodDuration)
            )
        } else {
            try? timebase.setTimerNextFireTime(periodEndTimer, fireTime: .invalid)
        }

        if finishedRendering, pendingPauseAtEndOfPeriod {
            pendingPauseAtEndOfPeriod = false
            try setPlayWhenReadyInternal(
                false,
                playbackSuppressionReason: playbackInfo.playbackSuppressionReason,
                operationAck: false,
                playWhenReadyChangeReason: .endOfMediaItem
            )
        }

        if renderersEnded {
            SELogger.verbose(.playback, "Renderers ended at clock \(mediaClock.getTimebase().time.seconds)")
        }

        if finishedRendering, playingPeriodHolder.info.isFinal {
            SELogger.info(.playback, "Ended at \(playbackInfo.position.seconds)")
            setState(.ended)
            stopRenderers()
        } else if playbackInfo.state == .buffering,
                  shouldTransitionToReadyState(renderersReadyOrEnded: renderersAllowPlayback) {
            SELogger.info(.playback, "Ready at \(playbackInfo.position.seconds), buffered to \(playbackInfo.bufferedPosition.seconds)")
            finishSeek(true, "ready")

            setState(.ready)
            cancelRecoveryTimeouts()
            pendingRecoverableRendererError = nil

            if shouldPlayWhenReady() {
                SELogger.debug(.playback, "Starting playback")
                updateRebufferingState(
                    isRebuffering: false,
                    resetLastRebufferRealtime: false
                )
                mediaClock.start()
                try startRenderers()
            }
        } else if playbackInfo.state == .ready,
                  !(enabledRendererCount == 0 ? isTimelineReady() : renderersAllowPlayback) {
            SELogger.info(.playback, "Buffering at \(playbackInfo.position.seconds), buffered to \(playbackInfo.bufferedPosition.seconds)\(isRebuffering ? " (rebuffering)" : "")")
            updateRebufferingState(isRebuffering: shouldPlayWhenReady(), resetLastRebufferRealtime: false)

            setState(.buffering)
            if isRebuffering {
                notifyTrackSelectionRebuffer()
                if shouldUseLivePlaybackSpeedControl(timeline: playbackInfo.timeline, periodId: playbackInfo.periodId) {
                    livePlaybackSpeedControl.notifyRebuffer()
                }
            }
            stopRenderers()
        }

        var playbackMaybeStuck = false
        if playbackInfo.state == .buffering {
            for (index, renderer) in renderers.enumerated() where renderer.isReading(from: playingPeriodHolder) {
                try maybeThrowRendererStreamError(rendererIndex: index)
            }

            if !playbackInfo.isLoading,
               playbackInfo.totalBufferedDuration < .from(microseconds: 500_000), // 500_000, // TODO: conts
               isLoadingPossible(mediaPeriodHolder: periodQueue.loading),
               shouldPlayWhenReady() {
                playbackMaybeStuck = true
            }
        }

        if !playbackMaybeStuck {
            playbackMaybeBecameStuckAt = .invalid
        } else if playbackMaybeBecameStuckAt.isValid == false {
            playbackMaybeBecameStuckAt = clock.time
        } else if (clock.time - playbackMaybeBecameStuckAt) >= Self.playbackStuckTimeout {
            // The load control holds off loading although the buffer is empty: nothing would ever start playback.
            throw PlaybackStuckError()
        }
    }

    /// While buffering, the player looks again after a while: a load can fail with a fatal error, or run out of retries,
    /// without telling it.
    private func scheduleBufferingWork() {
        guard playbackInfo.state == .buffering, !released else { return }
        workQueue.requestUpdate(after: .milliseconds(Self.bufferingWorkIntervalMs))
    }

    /// Throws the error of the next period once the renderers read the one before it to the end: until then, playback
    /// goes on, and a load that retries may still succeed.
    private func maybeThrowLoadingPeriodPrepareError() throws {
        guard let loading = periodQueue.loading, loading.prepareCalled, !loading.isPrepared,
              loading !== periodQueue.playing else {
            return
        }
        let reading = periodQueue.reading
        guard reading == nil || reading?.next === loading else { return }
        if let reading, !renderers.allSatisfy({ $0.hasFinishedReading(from: reading) }) { return }
        try loading.mediaPeriod.maybeThrowPrepareError()
    }

    private func maybeTriggerOnRendererReadyChanged(rendererIndex: Int, allowsPlayback: Bool) {
        if rendererReportedReady[rendererIndex] != allowsPlayback {
            rendererReportedReady[rendererIndex] = allowsPlayback
            // TODO: analyticsCollector
        }
    }

    /// The offset of the playback position from the live edge, or `.invalid` if the playing window isn't live.
    private func getCurrentLiveOffset() -> CMTime {
        getLiveOffset(timeline: playbackInfo.timeline, periodId: playbackInfo.periodId.periodId, periodPosition: playbackInfo.position)
    }

    /// How far a position of the period is behind the wall clock time of the live edge: a live window that dates its
    /// media knows when it is now.
    private func getLiveOffset(timeline: Timeline, periodId: AnyHashable, periodPosition: CMTime) -> CMTime {
        let windowIndex = timeline.periodById(periodId, period: period).windowIndex
        timeline.getWindow(windowIndex: windowIndex, window: window)
        guard window.windowStartTime.isNumeric, window.isLive, window.isDynamic, periodPosition.isNumeric else {
            return .invalid
        }
        return (window.currentUnixTime - window.windowStartTime) - (periodPosition + period.positionInWindow)
    }

    /// Whether the period is in a live window that dates its media, so the offset from the live edge is known.
    private func shouldUseLivePlaybackSpeedControl(timeline: Timeline, periodId: MediaPeriodId) -> Bool {
        guard !timeline.isEmpty, timeline.indexOfPeriod(by: periodId.periodId) != nil else {
            return false
        }
        let windowIndex = timeline.periodById(periodId.periodId, period: period).windowIndex
        timeline.getWindow(windowIndex: windowIndex, window: window)
        return window.isLive && window.isDynamic && window.windowStartTime.isNumeric
    }

    /// The offset from the live edge playback aims at: the speed control's, else the media's for a live window whose
    /// edge isn't dated; `.invalid` if the period isn't live.
    private func targetLiveOffset(periodId: MediaPeriodId) -> CMTime {
        let timeline = playbackInfo.timeline
        if shouldUseLivePlaybackSpeedControl(timeline: timeline, periodId: periodId) {
            return livePlaybackSpeedControl.targetLiveOffset
        }
        guard !timeline.isEmpty, timeline.indexOfPeriod(by: periodId.periodId) != nil else {
            return .invalid
        }
        let windowIndex = timeline.periodById(periodId.periodId, period: period).windowIndex
        timeline.getWindow(windowIndex: windowIndex, window: window)
        guard window.isDynamic, let liveConfiguration = window.liveConfiguration else {
            return .invalid
        }
        return liveConfiguration.targetOffset
    }

    private func seekToInternal(
        seekPosition: SeekPosition,
        incrementAcks: Bool,
        seekParameters: SeekParameters,
        completion: ((Bool) -> Void)?
    ) throws {
        assert(queue.isCurrent())
        // A seek that waited is older than this one: it would only be undone.
        if let pending = pendingScrubbingSeek {
            pendingScrubbingSeek = nil
            playbackInfoUpdate.incrementPendingOperationAcks(1)
            pending.completion?(false)
        }
        finishSeek(false, "a new seek")
        seekCompletion = completion
        seekStartTime = .now()
        // Before the position is adjusted: a scrubbing period can land on other keyframes.
        setScrubbing(!playbackInfo.playWhenReady && (scrubbingModeEnabled || seekParameters.allowsTolerance))

        playbackInfoUpdate.incrementPendingOperationAcks(incrementAcks ? 1 : 0)
        SELogger.info(.seek, "Seek to \(seekPosition.windowPosition.seconds) in window \(seekPosition.windowIndex), tolerance \(seekParameters.toleranceBefore.seconds)/\(seekParameters.toleranceAfter.seconds)\(isScrubbing ? ", scrubbing" : "")")

        let periodId: MediaPeriodId
        var periodPosition: CMTime
        let requestedContentPosition: CMTime
        var seekPositionAdjusted: Bool

        let resolvedSeekPosition = resolveSeekPosition(
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
            let resolvedContentPosition = resolvedSeekPosition.periodPosition
            requestedContentPosition = seekPosition.windowPosition.isValid ? resolvedContentPosition : .invalid
            periodId = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
                timeline: playbackInfo.timeline,
                periodId: periodUUID,
                position: resolvedContentPosition
            )
            periodPosition = resolvedContentPosition
            seekPositionAdjusted = seekPosition.windowPosition.isValid == false
        } else {
            let firstPeriodAndPosition = placeholderFirstMediaPeriodPosition(timeline: playbackInfo.timeline)
            periodId = firstPeriodAndPosition.0
            periodPosition = firstPeriodAndPosition.1
            requestedContentPosition = .invalid
            seekPositionAdjusted = !playbackInfo.timeline.isEmpty
        }

        let finalBlock = { [self] in
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: periodId,
                position: periodPosition,
                requestedContentPosition: requestedContentPosition,
                discontinuityStartPosition: periodPosition,
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
                SELogger.warning(.seek, "No position to seek to in the timeline: playback ends")
                finishSeek(false, "no position")
            } else {
                // Execute the seek in the current media periods.
                var newPeriodPosition = periodPosition
                if periodId == playbackInfo.periodId {
                    // The position is only refreshed by `doSomeWork`; compare against where playback
                    // actually is, not where it was last time.
                    try updatePlaybackPositionsInternal()

                    if let playing = periodQueue.playing, playing.isPrepared, CMTimeCompare(newPeriodPosition, .zero) != 0 {
                        newPeriodPosition = playing.mediaPeriod.getAdjustedSeekPosition(
                            position: newPeriodPosition,
                            seekParameters: seekParameters
                        )
                    }

                    if newPeriodPosition == playbackInfo.position,
                       playbackInfo.state == .buffering || playbackInfo.state == .ready {
                        periodPosition = playbackInfo.position

                        playbackInfo = handlePositionDiscontinuity(
                            mediaPeriodId: periodId,
                            position: periodPosition,
                            requestedContentPosition: requestedContentPosition,
                            discontinuityStartPosition: periodPosition,
                            reportDiscontinuity: seekPositionAdjusted,
                            discontinuityReason: .seekAdjustment
                        )

                        // Already there. While buffering, the seek completes as one to another position does: once
                        // the frame shows when paused, or the renderers can start. Nothing changes to tell the player:
                        // it looks now, rather than with its next look while buffering, a second later.
                        if playbackInfo.state == .ready {
                            finishSeek(true, "already at the position")
                        } else {
                            workQueue.requestUpdate()
                        }
                        return
                    }
                }

                // Within the item, the picture stays until the frame at the new position replaces it, also when the
                // renderers have to be disabled, as when they already read into the next period of a repeated item.
                let seek = { [self] in
                    try seekToPeriodPosition(
                        periodId: periodId,
                        periodPosition: newPeriodPosition,
                        forceBufferingState: playbackInfo.state == .ended
                    )
                }
                newPeriodPosition = try periodId == playbackInfo.periodId
                    ? preservingDisplayedImage(seek)
                    : seek()

                seekPositionAdjusted = seekPositionAdjusted || periodPosition != newPeriodPosition
                periodPosition = newPeriodPosition
                try updatePlaybackSpeedSettingsForNewPeriod(
                    newTimeline: playbackInfo.timeline,
                    newPeriodId: periodId,
                    oldTimeline: playbackInfo.timeline,
                    oldPeriodId: playbackInfo.periodId,
                    positionForTargetOffsetOverride: requestedContentPosition,
                    forceSetTargetOffsetOverride: true
                )
            }
            finalBlock()
        } catch {
            finalBlock()
            throw error
        }
    }

    /// Tells the periods whether seeks only need to show their frame.
    private func setScrubbing(_ isScrubbing: Bool) {
        guard isScrubbing != self.isScrubbing else { return }
        SELogger.info(.seek, isScrubbing ? "Scrubbing: seeks only need their frame" : "Scrubbing ends")
        self.isScrubbing = isScrubbing
        var holder = periodQueue.playing
        while let period = holder {
            period.mediaPeriod.setScrubbing(isScrubbing)
            holder = period.next
        }
    }

    /// Calls the completion of the seek once it did what its caller waits for. Neither case waits for the buffer that
    /// playback starts with:
    /// - while playback is due, once the renderers can start;
    /// - while paused, once the video shows the frame at the position, or the other renderers could start without
    ///   video.
    private func maybeCompleteSeek(playingPeriodHolder: MediaPeriodHolder, renderersAllowPlayback: Bool) {
        guard seekCompletion != nil, playingPeriodHolder.isPrepared else {
            return
        }

        let isDone: Bool
        let reason: String
        if enabledRendererCount == 0 {
            isDone = isTimelineReady()
            reason = "the timeline is ready"
        } else if shouldPlayWhenReady() {
            isDone = renderersAllowPlayback
            reason = "the renderers can start"
        } else {
            let videoRenderers = renderers.filter { $0.trackType == .video && $0.enabledRendererCount > 0 }
            isDone = videoRenderers.isEmpty
                ? renderersAllowPlayback
                : videoRenderers.allSatisfy { $0.hasPresentedOutput(playingPeriodHolder: playingPeriodHolder) }
            reason = videoRenderers.isEmpty ? "the renderers can start" : "the frame shows"
        }

        if isDone {
            finishSeek(true, reason)
        }
    }

    /// Calls the completion of the pending seek, if any.
    private func finishSeek(_ finished: Bool, _ reason: @autoclosure () -> String) {
        guard let seekCompletion else { return }
        let milliseconds = seekStartTime.map { $0.distance(to: .now()).totalMilliseconds } ?? 0
        if finished {
            SELogger.info(.seek, "Seek done in \(milliseconds)ms at \(playbackInfo.position.seconds): \(reason())")
        } else {
            SELogger.debug(.seek, "Seek given up after \(milliseconds)ms: \(reason())")
        }
        self.seekCompletion = nil
        seekStartTime = nil
        seekCompletion(finished)
        runPendingScrubbingSeek()
    }

    /// Whether a seek waits for the scrubbing seek in flight: while paused, for at most ``maxScrubbingSeekWait``.
    private func waitsForScrubbingSeek() -> Bool {
        guard isScrubbing, !playbackInfo.playWhenReady, seekCompletion != nil, let seekStartTime else {
            return false
        }
        return DispatchTime.now() < seekStartTime + Self.maxScrubbingSeekWait
    }

    /// Runs the seek that waited for the scrubbing seek in flight, if any.
    private func runPendingScrubbingSeek() {
        guard let pending = pendingScrubbingSeek else { return }
        pendingScrubbingSeek = nil
        postSeek(pending)
    }

    private struct PendingSeek {
        let timeline: Timeline
        let windowIndex: Int
        let position: CMTime
        let seekParameters: SeekParameters
        /// When it was asked for, among seeks.
        let sequence: Int
        let completion: ((Bool) -> Void)?
    }

    private func seekToPeriodPosition(
        periodId: MediaPeriodId,
        periodPosition: CMTime,
        forceBufferingState: Bool,
    ) throws -> CMTime {
        try seekToPeriodPosition(
            periodId: periodId,
            periodPosition: periodPosition,
            forceDisableRenderers: periodQueue.playing !== periodQueue.reading,
            forceBufferingState: forceBufferingState,
        )
    }

    private func seekToPeriodPosition(
        periodId: MediaPeriodId,
        periodPosition: CMTime,
        forceDisableRenderers: Bool,
        forceBufferingState: Bool,
        isRecoverySeek: Bool = false
    ) throws -> CMTime {
        var periodPosition = periodPosition

        let oldPlayingPeriodHolder = periodQueue.playing
        var newPlayingPeriodHolder = oldPlayingPeriodHolder

        while let unwrappedPeriod = newPlayingPeriodHolder {
            if periodId == unwrappedPeriod.info.id { break }
            newPlayingPeriodHolder = unwrappedPeriod.next
        }

        let newPlayingPeriodCheck = if let newPlayingPeriodHolder {
            newPlayingPeriodHolder.toRendererTime(periodTime: periodPosition) < .zero // TODO: check for correctn
        } else {
            false
        }

        let shouldResetRenderers =
            forceDisableRenderers ||
            oldPlayingPeriodHolder !== newPlayingPeriodHolder || newPlayingPeriodCheck

        // Stopping the clock waits for the audio output to stop, and resetting the renderers for it to flush: tens of
        // milliseconds. A seek within the playing period loads from the new position before both, so its requests go
        // out meanwhile.
        let loadsBeforeStoppingOutput = !shouldResetRenderers
            && newPlayingPeriodHolder?.isPrepared == true
            && newPlayingPeriodHolder?.hasEnabledTracks == true
        if loadsBeforeStoppingOutput {
            renderers.forEach { $0.stop() }
        } else {
            stopRenderers()
        }
        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtime: true)
        if forceBufferingState || playbackInfo.state == .ready {
            setState(.buffering)
        }

        if shouldResetRenderers {
            try disableRenderers()
            if let newPlayingPeriodHolder {
                while periodQueue.playing != newPlayingPeriodHolder {
                    periodQueue.advancePlayingPeriod()
                }
                periodQueue.removeAfter(mediaPeriodHolder: newPlayingPeriodHolder)
                newPlayingPeriodHolder.renderPositionOffset = MediaPeriodQueue.initialRendererPositionOffset
                try enableRenderers()
                newPlayingPeriodHolder.allRenderersInCorrectState = true
            }
        }

        disableAndResetPrewarmingRenderers()
        if let newPlayingPeriodHolder {
            periodQueue.removeAfter(mediaPeriodHolder: newPlayingPeriodHolder)

            if !newPlayingPeriodHolder.isPrepared {
                newPlayingPeriodHolder.info = newPlayingPeriodHolder.info.copyWithStartPosition(periodPosition)
            } else if newPlayingPeriodHolder.hasEnabledTracks {
                periodPosition = try isRecoverySeek
                    ? newPlayingPeriodHolder.mediaPeriod.seekForRecovery(position: periodPosition)
                    : newPlayingPeriodHolder.mediaPeriod.seek(position: periodPosition)
                try newPlayingPeriodHolder.mediaPeriod.discardBuffer(
                    position: periodPosition - backBufferDuration,
                    toKeyframe: retainBackBufferFromKeyframe
                )
            }

            if loadsBeforeStoppingOutput {
                // The clock still runs from the old position: loading decides from the new one.
                try maybeContinueLoading(from: newPlayingPeriodHolder.toRendererTime(periodTime: periodPosition))
                mediaClock.stop()
                try resetRendererPosition(periodPosition: periodPosition)
            } else {
                try resetRendererPosition(periodPosition: periodPosition)
                try maybeContinueLoading()
            }
        } else {
            periodQueue.clear()
            try resetRendererPosition(periodPosition: periodPosition)
        }

        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
        workQueue.requestUpdate()

        return periodPosition
    }

    private func resetRendererPosition(periodPosition: CMTime) throws {
        let playingMediaPeriod = periodQueue.playing
        rendererPosition = if let playingMediaPeriod {
            playingMediaPeriod.toRendererTime(periodTime: periodPosition)
        } else {
            MediaPeriodQueue.initialRendererPositionOffset + periodPosition
        }

        try renderers.forEach {
            try $0.resetPosition(for: playingMediaPeriod, position: rendererPosition)
        }
        mediaClock.resetPosition(position: rendererPosition)
        syncOutboundTimebase()
        notifyTrackSelectionDiscontinuity()
    }

    /// Puts the public timebase at the playing period's position. It follows the renderer timebase
    /// on its own, so this is only needed when the renderer-to-period mapping changes: after a
    /// position reset and when the playing period advances.
    private func syncOutboundTimebase() {
        guard let playing = periodQueue.playing else { return }
        try? outboundTimebase.setTime(to: playing.toPeriodTime(rendererTime: mediaClock.getTimebase().time))
    }

    private func setPlaybackParametersInternal(_ playbackParameters: PlaybackParameters) throws {
        assert(queue.isCurrent())
        try mediaClock.setPlaybackParameters(new: playbackParameters)
        try! handlePlaybackParameters(
            playbackParameters: mediaClock.getPlaybackParameters(),
            acknowledgeCommand: true
        )
    }

    private func setVideoOutputInternal(_ output: any VideoOutput) throws {
        try renderers.forEach { try $0.setVideoOutput(output) }
    }

    private func removeVideoOutputInternal(_ output: any VideoOutput) throws {
        try renderers.forEach { try $0.removeVideoOutput(output) }
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
        do {
            resetInternal(
                resetRenderers: true,
                resetPosition: false,
                releaseMediaSourceList: true,
                resetError: false
            )
            try outboundTimebase.setRate(to: 1.0)
            releaseRenderers()
            loadControl.onReleased(playerId: identifier)
            trackSelector.release()
            setState(.idle)
            // Nothing runs after the release, posted already or later.
            released = true
            workQueue.invalidate()
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
        workQueue.cancelPendingUpdates()
        pendingRendererRecoveries.removeAll()
        rendererRecoveryBackoffs.removeAll()
        delayedRendererRecoveries.removeAll()
        cancelRecoveryTimeouts()
        updateRebufferingState(isRebuffering: false, resetLastRebufferRealtime: true)
        mediaClock.stop()
        rendererPosition = MediaPeriodQueue.initialRendererPositionOffset

        do {
            try disableRenderers()
        } catch {
            // The reset goes on regardless.
            SELogger.error(.lifecycle, "Disabling the renderers failed: \(error)")
        }

        if resetRenderers { renderers.forEach { $0.reset() } }
        enabledRendererCount = 0

        var mediaPeriodId = playbackInfo.periodId
        var startPosition = playbackInfo.position
        var requestedContentPosition = if isUsingPlaceholderPeriod(playbackInfo: playbackInfo, period: period) {
            playbackInfo.requestedContentPosition
        } else {
            playbackInfo.position
        }
        var resetTrackInfo = false
        if resetPosition {
            pendingInitialSeekPosition = nil
            let firstPeriodAndPosition = placeholderFirstMediaPeriodPosition(timeline: playbackInfo.timeline)
            mediaPeriodId = firstPeriodAndPosition.0
            startPosition = firstPeriodAndPosition.1
            requestedContentPosition = .invalid
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
            requestedContentPosition: requestedContentPosition,
            discontinuityStartPosition: startPosition,
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
            bufferedPosition: startPosition,
            totalBufferedDuration: .zero,
            position: startPosition,
            positionUpdateTime: .zero
        )

        if releaseMediaSourceList {
            periodQueue.releasePreloadPool()
            mediaSourceList.release()
        }
    }

    private func placeholderFirstMediaPeriodPosition(timeline: Timeline) -> (MediaPeriodId, CMTime) {
        assert(queue.isCurrent())
        guard !timeline.isEmpty,
              let firstWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled),
              let (firtsPeriodId, position) = timeline.periodPosition(
                  window: window,
                  period: period,
                  windowIndex: firstWindowIndex,
                  windowPosition: .invalid
              ) else {
            return (PlaybackInfo.placeholderMediaPeriodId, CMTime.zero)
        }

        let firstPeriodId = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
            timeline: timeline,
            periodId: firtsPeriodId,
            position: .zero
        )

        return (firstPeriodId, position)
    }

    private func sendMessageInternal(_ message: PlayerMessage) throws {
        if message.position.isValid == false {
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
            // A task, as the target is async; it runs on the player's queue, in order with the posted work.
            Task { [weak self] in
                guard let self else { return }
                SELogger.verbose(.scheduling, "Runs deliverMessage(\(message.type))")
                await deliverMessage(message, isolation: queue.playerActor())
                // The task goes on off the queue: the state is read on it.
                post("messageDelivered") { player in
                    if [.ready, .buffering].contains(player.playbackInfo.state) {
                        player.workQueue.requestUpdate()
                    }
                }
            }
        } else {
            post("sendMessageToTargetQueue") { try $0.sendMessageToTargetQueue(message) }
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

    private func maybeTriggerPendingMessages(oldPeriodPosition: CMTime, newPeriodPosition: CMTime) throws {
        if pendingMessages.isEmpty /* TODO: || playbackInfo.periodId.isAd */ {
            return
        }

        var oldPeriodPosition = oldPeriodPosition
        if deliverPendingMessageAtStartPositionRequired {
//            TODO: check oldPeriodPosition = oldPeriodPosition - CMTime(value: -1, timescale: oldPeriodPosition.timescale)
            deliverPendingMessageAtStartPositionRequired = false
        }

        let currentPeriodIndex = playbackInfo.timeline.indexOfPeriod(by: playbackInfo.periodId.periodId)
        var nextPendingMessageIndex = min(nextPendingMessageIndexHint, pendingMessages.count)
        var previousInfo = nextPendingMessageIndex > 0 ? pendingMessages[nextPendingMessageIndex - 1] : nil

        while let info = previousInfo {
            if (info.resolvedPeriodIndex > currentPeriodIndex ?? -1) || (info.resolvedPeriodIndex == currentPeriodIndex && info.resolvedPeriodTime > oldPeriodPosition) {
                nextPendingMessageIndex -= 1
                previousInfo = nextPendingMessageIndex > 0 ? pendingMessages[nextPendingMessageIndex - 1] : nil
            } else {
                break
            }
        }

        var nextInfo = nextPendingMessageIndex < pendingMessages.count ? pendingMessages[nextPendingMessageIndex] : nil
        while let info = nextInfo {
            if info.resolvedPeriodUid != nil && (info.resolvedPeriodIndex < currentPeriodIndex ?? -1 || (info.resolvedPeriodIndex == currentPeriodIndex && info.resolvedPeriodTime <= oldPeriodPosition)) {
                nextPendingMessageIndex += 1
                nextInfo = nextPendingMessageIndex < pendingMessages.count ? pendingMessages[nextPendingMessageIndex] : nil
            } else {
                break
            }
        }

        while let info = nextInfo, info.resolvedPeriodUid != nil,
              info.resolvedPeriodIndex == currentPeriodIndex,
              info.resolvedPeriodTime > oldPeriodPosition,
              info.resolvedPeriodTime <= newPeriodPosition {
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

        prewarmingMediaPeriodDiscontinuity = .invalid
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

        prewarmingMediaPeriodDiscontinuity = .invalid
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
        try updatePlaybackPositionsInternal()
        try reselectTracksInternal()
        try seekToCurrentPosition(sendDiscontinuity: true)
        try updatePeriods()
    }

    /// Applies new track selections to what loads from now on, so playback goes on uninterrupted: what is buffered
    /// plays out with the old selections.
    ///
    /// The track selector belongs to the player, so the player asks it for the selections of every prepared period
    /// and hands each period its own. How a period switches what it loads is up to its media period.
    private func reselectTracksForFutureLoads() throws {
        let playbackSpeed = mediaClock.getPlaybackParameters().playbackRate
        var hasChanged = false
        var hasPlayingPeriodChanged = false
        // The periods from the playing one up to the reading one are being read by the renderers.
        var isBeingRead = periodQueue.reading != nil
        var nextPeriod = periodQueue.playing

        while let period = nextPeriod, period.isPrepared {
            let isPeriodBeingRead = isBeingRead
            if period === periodQueue.reading {
                isBeingRead = false
            }
            nextPeriod = period.next

            let newSelections = try period.selectTracks(
                playbackSpeed: playbackSpeed,
                timeline: playbackInfo.timeline,
                playWhenReady: playbackInfo.playWhenReady
            )
            guard newSelections != period.trackSelectorResults else {
                continue
            }

            if period.updateTrackSelectionKeepingBuffer(newSelections) {
                hasChanged = true
                hasPlayingPeriodChanged = hasPlayingPeriodChanged || period === periodQueue.playing
                continue
            }

            // The media period can't switch while keeping its buffer, as for a track of another group.
            guard !isPeriodBeingRead else {
                // The renderers read this period, so its streams are replaced right away.
                try reselectTracksPreservingDisplayedImage()
                return
            }

            // The renderers haven't reached this period: it takes the new selections fully, and the periods
            // after it are loaded again.
            try replaceTrackSelection(of: period, with: newSelections)
            hasChanged = true
            break
        }

        guard hasChanged else { return }

        if hasPlayingPeriodChanged {
            // Publishes the new tracks. The position stays.
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: playbackInfo.periodId,
                position: playbackInfo.position,
                requestedContentPosition: playbackInfo.requestedContentPosition,
                discontinuityStartPosition: playbackInfo.discontinuityStartPosition,
                reportDiscontinuity: false,
                discontinuityReason: .internal
            )
        }
        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: true)

        if playbackInfo.state != .ended {
            try maybeContinueLoading()
            try updatePlaybackPositionsInternal()
            workQueue.requestUpdate()
        }
    }

    /// Gives a period the renderers haven't reached new streams for `newSelections`, and drops the periods after it.
    private func replaceTrackSelection(of period: MediaPeriodHolder, with newSelections: TrackSelectorResult) throws {
        periodQueue.removeAfter(mediaPeriodHolder: period)
        if hasSecondaryRenderers, areRenderersPrewarming(), periodQueue.prewarming == period {
            disableAndResetPrewarmingRenderers()
        }

        let positionInPeriod = period.toPeriodTime(rendererTime: rendererPosition)
        try period.applyTrackSelection(
            trackSelectorResult: newSelections,
            position: max(period.info.startPosition, positionInPeriod),
            forceRecreateStreams: false
        )
    }

    /// Applies new track selections to what is buffered right away. Playback waits for the new media, and the
    /// renderers keep showing the last picture meanwhile.
    private func reselectTracksPreservingDisplayedImage() throws {
        try preservingDisplayedImage(reselectTracksInternal)
    }

    /// Runs `body` with renderers that keep showing their last picture when they are disabled.
    private func preservingDisplayedImage<T>(_ body: () throws -> T) throws -> T {
        let outputs = renderers.flatMap { [$0.primaryRenderer, $0.secondaryRenderer].compactMap { $0 } }
        try outputs.forEach { try $0.handleMessage(.setPreservesDisplayedImageOnDisable(true)) }
        defer {
            outputs.forEach { try? $0.handleMessage(.setPreservesDisplayedImageOnDisable(false)) }
        }
        return try body()
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
                throw ErrorBuilder.illegalState()
            }
            let removeAfterResult = periodQueue.removeAfter(mediaPeriodHolder: playingPeriodHolder)
            let recreateStreams = removeAfterResult.contains(.alteredReadingPeriod)
            var streamResetFlags = Array(repeating: false, count: renderers.count)

            let periodPosition = try playingPeriodHolder.applyTrackSelection(
                newTrackSelectorResult: newPlayingPeriodTrackSelectorResult,
                position: playbackInfo.position,
                forceRecreateStreams: recreateStreams,
                streamResetFlags: &streamResetFlags
            )

            let hasDiscontinuity = playbackInfo.state != .ended && periodPosition != playbackInfo.position
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: playbackInfo.periodId,
                position: periodPosition,
                requestedContentPosition: playbackInfo.requestedContentPosition,
                discontinuityStartPosition: playbackInfo.discontinuityStartPosition,
                reportDiscontinuity: hasDiscontinuity,
                discontinuityReason: .internal
            )

            if hasDiscontinuity {
                try resetRendererPosition(periodPosition: periodPosition)
            }

            disableAndResetPrewarmingRenderers()

            var rendererWasEnabledFlags = Array(repeating: false, count: renderers.count)
            for (index, renderer) in renderers.enumerated() {
                let enabledRendererCountBeforeDisabling = renderer.enabledRendererCount
                rendererWasEnabledFlags[index] = renderer.isRendererEnabled

                try renderer.maybeDisableOrResetPosition2(
                    sampleStream: playingPeriodHolder.sampleStreams[index],
                    mediaClock: mediaClock,
                    rendererPosition: rendererPosition,
                    streamReset: streamResetFlags[index]
                )

                if enabledRendererCountBeforeDisabling - renderer.enabledRendererCount > 0 {
                    maybeTriggerOnRendererReadyChanged(rendererIndex: index, allowsPlayback: false)
                }

                enabledRendererCount -= enabledRendererCountBeforeDisabling - renderer.enabledRendererCount
            }

            try enableRenderers(
                rendererWasEnabledFlags: rendererWasEnabledFlags,
                startPosition: rendererPosition
            )
            playingPeriodHolder.allRenderersInCorrectState = true
        } else {
            guard let periodHolder else { return }
            periodQueue.removeAfter(mediaPeriodHolder: periodHolder)
            if periodHolder.isPrepared {
                let loadingPeriodPosition = max(
                    periodHolder.info.startPosition,
                    periodHolder.toPeriodTime(rendererTime: rendererPosition)
                )

                if hasSecondaryRenderers,
                   areRenderersPrewarming(),
                   periodQueue.prewarming == periodHolder {
                    disableAndResetPrewarmingRenderers()
                }

                try periodHolder.applyTrackSelection(
                    trackSelectorResult: newTrackSelectorResult,
                    position: loadingPeriodPosition,
                    forceRecreateStreams: false
                )
            }
        }

        handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: true)
        if playbackInfo.state != .ended {
            try maybeContinueLoading()
            try updatePlaybackPositionsInternal()
            workQueue.requestUpdate()
        }
    }

    private func updateTrackSelectionPlaybackSpeed(playbackSpeed: Float) {
        var periodHolder = periodQueue.playing
        while let unwrappedPeriodHolder = periodHolder {
            unwrappedPeriodHolder.trackSelectorResults.selections.forEach {
                $0?.playbackSpeedDidChange(playbackSpeed)
            }
            periodHolder = unwrappedPeriodHolder.next
        }
    }

    private func notifyTrackSelectionDiscontinuity() {
        // TODO: make
    }

    private func shouldTransitionToReadyState(renderersReadyOrEnded: Bool) -> Bool {
        guard enabledRendererCount > 0 else { return isTimelineReady() }
        guard renderersReadyOrEnded else { return false }
        guard playbackInfo.isLoading else { return true }
        guard let playingPeriodHolder = periodQueue.playing,
              let loadingHolder = periodQueue.loading else {
            return false
        }

        let isBufferedToEnd = loadingHolder.isFullyBuffered() && loadingHolder.info.isFinal
        if isBufferedToEnd { // TODO: isAdPendingPreparation
            return true
        }

        return loadControl.shouldStartPlayback(
            parameters: readinessParameters(playing: playingPeriodHolder, loading: loadingHolder)
        )
    }

    /// What `LoadControl.shouldStartPlayback` decides with.
    private func readinessParameters(playing: MediaPeriodHolder, loading: MediaPeriodHolder) -> LoadControlParams {
        // From the playback position to the buffered position of the loading
        // period. What is still queued in the sample streams leaves out media a renderer has
        // already taken, so sparse media looked unbuffered.
        let bufferedDuration = getTotalBufferedDuration(bufferedPositionInLoadingPeriod: loading.getBufferedPosition())

        return LoadControlParams(
            playerId: identifier,
            timeline: playbackInfo.timeline,
            mediaPeriodId: playing.info.id,
            playbackPosition: playing.toPeriodTime(rendererTime: rendererPosition),
            bufferedDuration: bufferedDuration,
            playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
            playWhenReady: playbackInfo.playWhenReady,
            rebuffering: isRebuffering,
            targetLiveOffset: targetLiveOffset(periodId: playing.info.id),
            lastRebufferRealtime: lastRebufferRealtime
        )
    }

    /// Media buffered ahead of the playback position, from the playing period through the loading
    /// one. The periods before the loading one are fully loaded, so all of their remaining media
    /// counts, not just the loading period's.
    private func totalBufferedAheadDuration() -> CMTime {
        var total = CMTime.zero
        var holder = periodQueue.playing

        while let period = holder {
            total = total + bufferedAhead(of: period)

            if period === periodQueue.loading { break }
            holder = period.next
        }

        return total
    }

    private func isTimelineReady() -> Bool {
        guard let playingPeriodHolder = periodQueue.playing else {
            return false
        }

        let playingPeriodDuration = playingPeriodHolder.info.duration
        return playingPeriodHolder.isPrepared
            && (playingPeriodDuration.isValid == false
                || playbackInfo.position < playingPeriodDuration
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
        let newRequestedContentPosition = positionUpdate.requestedContentPosition
        let forceBufferingState = positionUpdate.forceBufferingState
        var newPosition = positionUpdate.periodPosition
        let periodPositionChanged = playbackInfo.periodId != newPeriodId || newPosition != playbackInfo.position

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
            let maxRendererReadPosition: CMTime = if let reading = periodQueue.reading {
                self.maxRendererReadPosition(periodHolder: reading)
            } else {
                .zero
            }

            let maxRendererPrewarmingPositionUs: CMTime = if let prewarming = periodQueue.prewarming, !areRenderersPrewarming() {
                self.maxRendererReadPosition(periodHolder: prewarming)
            } else {
                .zero
            }

            let updateQueuedPeriodsResult = periodQueue.updateQueuedPeriods(
                timeline: timeline,
                rendererPosition: rendererPosition,
                maxRendererReadPosition: maxRendererReadPosition,
                maxRendererPrewarmingPosition: maxRendererPrewarmingPositionUs
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

            newPosition = try! seekToPeriodPosition(
                periodId: newPeriodId,
                periodPosition: newPosition,
                forceBufferingState: forceBufferingState
            )
        }

        try! updatePlaybackSpeedSettingsForNewPeriod(
            newTimeline: timeline,
            newPeriodId: newPeriodId,
            oldTimeline: playbackInfo.timeline,
            oldPeriodId: playbackInfo.periodId,
            positionForTargetOffsetOverride: positionUpdate.setTargetLiveOffset ? newPosition : .invalid,
            forceSetTargetOffsetOverride: false
        )

        if periodPositionChanged || newRequestedContentPosition != playbackInfo.requestedContentPosition {
            let oldPeriodId = playbackInfo.periodId.periodId
            let oldTimeline = playbackInfo.timeline
            let reportDiscontinuity = periodPositionChanged
            && isSourceRefresh
            && !oldTimeline.isEmpty
            && !oldTimeline.periodById(oldPeriodId, period: period).isPlaceholder

            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: newPeriodId,
                position: newPosition,
                requestedContentPosition: newRequestedContentPosition,
                discontinuityStartPosition: playbackInfo.discontinuityStartPosition,
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
        workQueue.requestUpdate()
    }

    private func updatePlaybackSpeedSettingsForNewPeriod(
        newTimeline: Timeline,
        newPeriodId: MediaPeriodId,
        oldTimeline: Timeline,
        oldPeriodId: MediaPeriodId,
        positionForTargetOffsetOverride: CMTime,
        forceSetTargetOffsetOverride: Bool
    ) throws {
        guard shouldUseLivePlaybackSpeedControl(timeline: newTimeline, periodId: newPeriodId) else {
            // Outside live windows the speed is the one asked for.
            if mediaClock.getPlaybackParameters() != playbackInfo.playbackParameters {
                try setMediaClockPlaybackParameters(playbackParameters: playbackInfo.playbackParameters)
                try handlePlaybackParameters(
                    playbackParameters: playbackInfo.playbackParameters,
                    currentPlaybackSpeed: playbackInfo.playbackParameters.playbackRate,
                    updatePlaybackInfo: false,
                    acknowledgeCommand: false
                )
            }
            return
        }

        let windowIndex = newTimeline.periodById(newPeriodId.periodId, period: period).windowIndex
        newTimeline.getWindow(windowIndex: windowIndex, window: window)
        if let liveConfiguration = window.liveConfiguration {
            livePlaybackSpeedControl.setLiveConfiguration(liveConfiguration)
        }
        if positionForTargetOffsetOverride.isValid {
            // A seek inside the live window keeps the offset it went to.
            livePlaybackSpeedControl.setTargetLiveOffsetOverride(getLiveOffset(
                timeline: newTimeline,
                periodId: newPeriodId.periodId,
                periodPosition: positionForTargetOffsetOverride
            ))
        } else {
            let windowId = window.id
            var oldWindowId: AnyHashable?
            if !oldTimeline.isEmpty, oldTimeline.indexOfPeriod(by: oldPeriodId.periodId) != nil {
                let oldWindowIndex = oldTimeline.periodById(oldPeriodId.periodId, period: period).windowIndex
                oldWindowId = oldTimeline.getWindow(windowIndex: oldWindowIndex, window: window).id
            }
            // Another window, or a seek to the default position, goes back to the media's offset.
            if oldWindowId != windowId || forceSetTargetOffsetOverride {
                livePlaybackSpeedControl.setTargetLiveOffsetOverride(.invalid)
            }
        }
    }

    private func maxRendererReadPosition(periodHolder: MediaPeriodHolder?) -> CMTime {
        assert(queue.isCurrent())
        guard let periodHolder else { return .zero }

        var maxReadPosition = periodHolder.renderPositionOffset
        guard periodHolder.isPrepared else { return maxReadPosition }

        for renderer in renderers where !renderer.isReading(from: periodHolder) {
            let readingPosition = renderer.readingPosition(for: periodHolder)
            if readingPosition.isPositiveInfinity {
                return .positiveInfinity
            } else {
                maxReadPosition = max(readingPosition, maxReadPosition)
            }
        }

        return maxReadPosition
    }

    private func updatePeriods() throws {
        if playbackInfo.timeline.isEmpty || !mediaSourceList.isPrepared {
            // Still waiting for the sources to tell what they play.
            try mediaSourceList.maybeThrowSourceInfoRefreshError()
            return
        }

        rendererPosition = mediaClock
            .syncAndGetPosition(
                isReadingAhead: periodQueue.playing !== periodQueue.reading
            )

        let loadingPeriodChanged = try! maybeUpdateLoadingPeriod()
        try! maybeUpdatePrewarmingPeriod()
        try! maybeUpdateReadingPeriod()
        try! maybeUpdateReadingRenderers()
        try! maybeUpdatePlayingPeriod()
        try! maybeUpdatePreloadPeriods(loadingPeriodChanged: loadingPeriodChanged)
        try updateTriggersForPeriods()
    }

    private func maybeUpdateLoadingPeriod() throws -> Bool {
        var loadingPeriodChanged = false
        periodQueue.reevaluateBuffer(rendererPosition: rendererPosition)
        if periodQueue.shouldLoadNextMediaPeriod(),
           let info = periodQueue.nextMediaPeriodInfo(rendererPosition: rendererPosition, playbackInfo: playbackInfo) {
            let mediaPeriodHolder = try! periodQueue.enqueueNextMediaPeriodHolder(info: info)
            SELogger.info(.periods, "Loading a period from \(info.startPosition.seconds)\(info.endPosition.isValid ? " to \(info.endPosition.seconds)" : "")\(info.isFinal ? ", the last" : "")")
            if !mediaPeriodHolder.prepareCalled {
                mediaPeriodHolder.prepare(callback: self, on: info.startPosition)
            } else if mediaPeriodHolder.isPrepared {
                didPrepare(mediaPeriod: mediaPeriodHolder.mediaPeriod)
            }

            if periodQueue.playing === mediaPeriodHolder {
                try! resetRendererPosition(periodPosition: info.startPosition)
            }

            handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
            loadingPeriodChanged = true
        }

        if shouldContinueLoading {
            shouldContinueLoading = isLoadingPossible(mediaPeriodHolder: periodQueue.loading)
            updateIsLoading()
        } else {
            try maybeContinueLoading()
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
                    startPosition: prewarmingPeriod.getStartPositionRendererTime()
                )
            }
        }

        if areRenderersPrewarming() {
            prewarmingMediaPeriodDiscontinuity = prewarmingPeriod.mediaPeriod.readDiscontinuity()
            if !prewarmingPeriod.isFullyBuffered() {
                periodQueue.removeAfter(mediaPeriodHolder: prewarmingPeriod)
                handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                try maybeContinueLoading()
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
                    let streamEndPosition: CMTime = if readingPeriodHolder.info.duration.isValid,
                                                      !readingPeriodHolder.info.duration.isPositiveInfinity {
                        readingPeriodHolder.renderPositionOffset + readingPeriodHolder.info.duration
                    } else {
                        .invalid
                    }
                    renderer.setCurrentStreamFinal(for: readingPeriodHolder, streamEndPosition: streamEndPosition)
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
            && rendererPosition < next.getStartPositionRendererTime() {
            return
        }

        let oldReadingPeriodHolder = readingPeriodHolder
        let oldTrackSelectorResult = readingPeriodHolder.trackSelectorResults
        guard let readingPeriodHolder = periodQueue.advanceReadingPeriod() else {
            return
        }
        SELogger.info(.periods, "Renderers read the next period, from \(readingPeriodHolder.info.startPosition.seconds)")
        let newTrackSelectorResult = readingPeriodHolder.trackSelectorResults

        try! updatePlaybackSpeedSettingsForNewPeriod(
            newTimeline: playbackInfo.timeline,
            newPeriodId: readingPeriodHolder.info.id,
            oldTimeline: playbackInfo.timeline,
            oldPeriodId: oldReadingPeriodHolder.info.id,
            positionForTargetOffsetOverride: .invalid,
            forceSetTargetOffsetOverride: false
        )

        if readingPeriodHolder.isPrepared,
           (hasSecondaryRenderers && prewarmingMediaPeriodDiscontinuity.isValid) ||
            (readingPeriodHolder.mediaPeriod.readDiscontinuity().isValid) {
            prewarmingMediaPeriodDiscontinuity = .invalid

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
                    streamEndPosition: readingPeriodHolder.getStartPositionRendererTime()
                )
                if !readingPeriodHolder.isFullyBuffered() {
                    periodQueue.removeAfter(mediaPeriodHolder: readingPeriodHolder)
                    handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
                    try maybeContinueLoading()
                }

                return
            }
        }

        renderers.forEach {
            $0.maybeSetOldStreamToFinal(
                oldTrackSelectorResult: oldTrackSelectorResult,
                newTrackSelectorResult: newTrackSelectorResult,
                streamEndPosition: readingPeriodHolder.getStartPositionRendererTime()
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

        if allUpdated {
            for (index, renderer) in renderers.enumerated() {
                if newTrackSelectorResult.isRendererEnabled(for: index), !renderer.isReading(from: readingMediaPeriod) {
                    try! enableRenderer(
                        periodHolder: readingMediaPeriod,
                        rendererIndex: index,
                        wasRendererEnabled: false,
                        startPosition: readingMediaPeriod.getStartPositionRendererTime()
                    )
                }
            }
        }

        return allUpdated
    }

    private func maybeUpdatePreloadPeriods(loadingPeriodChanged: Bool) throws {
        guard preloadConfiguration.targetPreloadDuration.isValid else {
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
                bufferedDuration: preloading.isPrepared ? preloading.mediaPeriod.getBufferedPosition() : .zero)
        else {
            return
        }

        if !preloading.prepareCalled {
            preloading.prepare(callback: self, on: preloading.info.startPosition)
        } else {
            preloading.continueLoading(
                loadingInfo: LoadingInfo(
                    playbackPosition: preloading.toPeriodTime(rendererTime: rendererPosition),
                    playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                    lastRebufferRealtime: lastRebufferRealtime
                )
            )

            preloading.changeDurationToStopLoadingTriggerTokens(
                loadControl.getMaxBufferDuration(playerId: identifier),
                streamIndices: bufferStreamIndices
            ) { [weak self] _ in
                self?.requestPeriodsUpdate()
            }
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
                throw ErrorBuilder.illegalState()
            }
            SELogger.info(.periods, "Playing the next period, from \(newPlayingPeriodHolder.info.startPosition.seconds)")

            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: newPlayingPeriodHolder.info.id,
                position: newPlayingPeriodHolder.info.startPosition,
                requestedContentPosition: newPlayingPeriodHolder.info.requestedContentPosition,
                discontinuityStartPosition: newPlayingPeriodHolder.info.startPosition,
                reportDiscontinuity: true,
                discontinuityReason: .autoTransition
            )

            resetPendingPauseAtEndOfPeriod()
            try! updatePlaybackPositionsInternal()
            syncOutboundTimebase()
            if areRenderersPrewarming(), newPlayingPeriodHolder == periodQueue.prewarming {
                try! maybeHandlePrewarmingTransition()
            }

            if playbackInfo.state == .ready {
                try! startRenderers()
            }

            allowRenderersToRenderStartOfStreams()
            advancedPlayingPeriod = true
        }

        if !advancedPlayingPeriod {
            guard !pendingPauseAtEndOfPeriod,
                  let playingPeriodHolder = periodQueue.playing,
                  let nextPlayingPeriodHolder = playingPeriodHolder.next,
                  nextPlayingPeriodHolder.getStartPositionRendererTime().isValid else {
                return
            }

            // Past the start of the next period, the transition waits for a renderer to finish, which reports it: a
            // timer set in the past would fire at once, again and again.
            let nextPeriodTime = nextPlayingPeriodHolder.getStartPositionRendererTime()
            let timebase = mediaClock.getTimebase()
            try! timebase.setTimerNextFireTime(eventTimer, fireTime: nextPeriodTime > timebase.time ? nextPeriodTime : .invalid)
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
              let nextPlayingPeriodHolder = playingPeriodHolder.next else {
            return false
        }

        rendererPosition = mediaClock.syncAndGetPosition(isReadingAhead: playingPeriodHolder !== periodQueue.reading)
        let result = rendererPosition >= nextPlayingPeriodHolder.getStartPositionRendererTime()
            && nextPlayingPeriodHolder.allRenderersInCorrectState

        SELogger.verbose(.periods, "Advance to the next period: \(result), renderer position \(rendererPosition.seconds), next starts at \(nextPlayingPeriodHolder.getStartPositionRendererTime().seconds)")
        return result
    }

    private func hasReadingPeriodFinishedReading() -> Bool {
        guard let reading = periodQueue.reading,
              reading.isPrepared else {
            return false
        }

        return renderers.allSatisfy { $0.hasFinishedReading(from: reading) }
    }

    private func setAllNonPrewarmingRendererStreamsFinal(streamEndPosition: CMTime) {
        renderers.forEach {
            $0.setAllNonPrewarmingRendererStreamsFinal(streamEndPosition: streamEndPosition)
        }
    }

    private func handlePeriodPrepared(mediaPeriod: MediaPeriod) throws {
        assert(queue.isCurrent())
        SELogger.info(.periods, "\(type(of: mediaPeriod)) prepared")
        if periodQueue.isLoading(mediaPeriod: mediaPeriod) {
            guard let loadingPeriod = periodQueue.loading else {
                return
            }
            try! handleLoadingPeriodPrepared(loadingPeriodHolder: loadingPeriod)

            // The "buffered enough to play" trigger needs a prepared period, so install it now.
            if playbackInfo.state == .buffering {
                workQueue.requestUpdate()
            }
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

            loadingPeriodHolder.changeDurationToStopLoadingTriggerTokens(
                loadControl.getMaxBufferDuration(playerId: identifier),
                streamIndices: bufferStreamIndices
            ) { [weak self] _ in
                self?.requestPeriodsUpdate()
            }
        }

        updateLoadControlTrackSelection(
            mediaPeriodId: loadingPeriodHolder.info.id,
            trackGroups: loadingPeriodHolder.trackGroups,
            trackSelectorResult: loadingPeriodHolder.trackSelectorResults
        )

        if loadingPeriodHolder === periodQueue.playing {
            try! resetRendererPosition(periodPosition: loadingPeriodHolder.info.startPosition)
            try! enableRenderers()
            loadingPeriodHolder.allRenderersInCorrectState = true
            playbackInfo = handlePositionDiscontinuity(
                mediaPeriodId: playbackInfo.periodId,
                position: loadingPeriodHolder.info.startPosition,
                requestedContentPosition: playbackInfo.requestedContentPosition,
                discontinuityStartPosition: loadingPeriodHolder.info.startPosition,
                reportDiscontinuity: false,
                discontinuityReason: .internal
            )
        }

        try maybeContinueLoading()
    }

    private func handleContinueLoadingRequested(mediaPeriod: MediaPeriod) throws {
        if periodQueue.isLoading(mediaPeriod: mediaPeriod) {
            try maybeContinueLoading()
            // Nothing else updates the buffered position while playback runs.
            handleLoadingMediaPeriodChanged(loadingTrackSelectionChanged: false)
            // A period loaded to its end makes room for the next one, which nothing else would enqueue before the
            // next update: then it would start loading at some random moment, or only when it is due to play.
            if periodQueue.shouldLoadNextMediaPeriod() {
                requestPeriodsUpdate()
            }
        } else if periodQueue.isPreloading(mediaPeriod: mediaPeriod) {
            maybeContinuePreloading()
        }

        // A load that finished or was cancelled can decide whether playback may start, e.g. when
        // the rest of the media is shorter than the buffer the player waits for.
        if playbackInfo.state == .buffering {
            workQueue.requestUpdate()
        }
    }

    private func updateTriggersForPeriods() throws {
        if let loadingPeriod = periodQueue.loading {
            if shouldContinueLoading {
                let currentPosition = loadingPeriod.sampleStreams
                    .compactMap { $0 }
                    .min(by: { $0.bufferedAheadDuration < $1.bufferedAheadDuration })?
                    .bufferedAheadDuration

                // TODO: don't do if duration is unknown
                loadingPeriod.changeDurationToStopLoadingTriggerTokens(
                    loadControl.getMaxBufferDuration(playerId: identifier),
                    streamIndices: bufferStreamIndices
                ) { [weak self] _ in
                    // The max buffer is reached: loading stops, and the periods update from there.
                    self?.post("stopLoading") { player in
                        player.shouldContinueLoading = false
                        try player.updatePeriods()
                    }
                }
            } else if !loadingPeriod.isFullyBuffered() {
                loadingPeriod.changeDurationToStopLoadingTriggerTokens(nil)
                loadingPeriod.mediaPeriod.stopLoading()
            }
        }

        updateStartLoadingTriggers()

        // While buffering, wake up once enough may be buffered to start. Only the loading period's buffer
        // still grows (the periods before it are fully loaded), so that is where the trigger goes: once its streams
        // hold media to where the loading period is buffered to now, and what the decision still misses.
        var playbackBufferedPosition: CMTime?
        if playbackInfo.state == .buffering, let playing = periodQueue.playing, let loading = periodQueue.loading {
            let parameters = readinessParameters(playing: playing, loading: loading)
            let missing = loadControl.bufferedDurationToCheckPlayback(parameters: parameters) - parameters.bufferedDuration
            let bufferedPosition = loading.getBufferedPosition()
            if missing > .zero, bufferedPosition.isNumeric {
                playbackBufferedPosition = bufferedPosition + missing
            }
        }

        var holder = periodQueue.playing
        while let period = holder {
            let isLoadingPeriod = period === periodQueue.loading

            if let playbackBufferedPosition, isLoadingPeriod {
                period.changeBufferedPositionForPlaybackTriggerTokens(playbackBufferedPosition, streamIndices: bufferStreamIndices) { [weak self] _ in
                    self?.workQueue.requestUpdate()
                }
            } else {
                period.changeBufferedPositionForPlaybackTriggerTokens(nil)
            }

            if isLoadingPeriod { break }
            holder = period.next
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
        updateTrackSelectionPlaybackSpeed(playbackSpeed: playbackParameters.playbackRate)
        try! renderers.forEach {
            try! $0.setPlaybackSpeed(current: currentPlaybackSpeed, target: playbackParameters.playbackRate)
        }
    }

    /// - Parameter position: The renderer position to decide from, instead of the clock's.
    private func maybeContinueLoading(from position: CMTime? = nil) throws {
        shouldContinueLoading = try shouldContinueLoadingPeriod(from: position)
        if shouldContinueLoading, let loadingPeriod = periodQueue.loading {
            loadingPeriod.continueLoading(loadingInfo: .init(
                playbackPosition: loadingPeriod.toPeriodTime(rendererTime: rendererPosition),
                playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                lastRebufferRealtime: lastRebufferRealtime
            ))
            // A period can load to its end at once, and then there is nothing more to load from it.
            if !isLoadingPossible(mediaPeriodHolder: loadingPeriod) {
                shouldContinueLoading = false
            }
        }

        updateIsLoading()
        // Every decision arms what wakes the player for the next one: the max buffer while loading, the min buffer
        // once paused. A load that completes decides here too, outside a period update, and with loading paused
        // and nothing armed, nothing would restart it before the buffer ran dry.
        try updateTriggersForPeriods()
    }

    private func shouldContinueLoadingPeriod(from position: CMTime? = nil) throws -> Bool {
        guard let loadingPeriod = periodQueue.loading, isLoadingPossible(mediaPeriodHolder: loadingPeriod) else {
            return false
        }

        rendererPosition = position ?? mediaClock
            .syncAndGetPosition(isReadingAhead: periodQueue.playing !== periodQueue.reading)

        // Everything buffered ahead, not only the loading period's: a period queued after a short one
        // starts near zero, and would load to its end, and the one after it too.
        let bufferedDuration = totalBufferedAheadDuration()

        let playbackPosition = if loadingPeriod == periodQueue.playing {
            loadingPeriod.toPeriodTime(rendererTime: rendererPosition)
        } else {
            loadingPeriod.toPeriodTime(rendererTime: rendererPosition) - loadingPeriod.info.startPosition
        }

        let loadParameters = LoadControlParams(
            playerId: identifier,
            timeline: playbackInfo.timeline,
            mediaPeriodId: loadingPeriod.info.id,
            playbackPosition: playbackPosition,
            bufferedDuration: bufferedDuration,
            playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
            playWhenReady: playbackInfo.playWhenReady,
            rebuffering: isRebuffering,
            targetLiveOffset: targetLiveOffset(periodId: loadingPeriod.info.id),
            lastRebufferRealtime: lastRebufferRealtime
        )

        // Loads start below the min buffer and go on until the max buffer: the media period pauses
        // every few bytes to ask, so answering "no" above the min buffer would stop loading there.
        var shouldContinueLoading = loadControl.shouldContinueLoading(with: loadParameters)

        if let playing = periodQueue.playing, !shouldContinueLoading,
           playing.isPrepared, bufferedDuration < .from(microseconds: 500_000), // TODO: conts
           backBufferDuration > .zero || retainBackBufferFromKeyframe {
            try playing.mediaPeriod.discardBuffer(position: playbackInfo.position, toKeyframe: false)
            shouldContinueLoading = loadControl.shouldContinueLoading(with: loadParameters)
        }

        return shouldContinueLoading
    }

    /// Wakes the player when loading should restart: when everything buffered ahead drops below the
    /// min buffer, which is when `shouldContinueLoadingPeriod` says yes again.
    ///
    /// The buffer drains only through the period the renderers read; the periods after it keep
    /// what they have while loading is paused. So the trigger goes on the reading period, for the
    /// min buffer less what the later periods hold. On the loading period instead, a next period
    /// with nothing loaded yet fires it at once while the total is still large, the answer is no,
    /// and the reinstalled trigger fires again, round and round on the player queue.
    private func updateStartLoadingTriggers() {
        let reading = periodQueue.reading ?? periodQueue.playing
        let isPaused = !shouldContinueLoading && periodQueue.loading.map { !$0.isFullyBuffered() } == true

        var periods: [MediaPeriodHolder] = []
        var holder = periodQueue.playing
        while let period = holder {
            periods.append(period)
            if period === periodQueue.loading { break }
            holder = period.next
        }

        let bufferedAfterReading = periods
            .drop { $0 !== reading }
            .dropFirst()
            .reduce(CMTime.zero) { $0 + bufferedAhead(of: $1) }
        // With more than the min buffer after the reading period, nothing drops below it until the
        // reading period ends, and that advance runs this again.
        var threshold = minBufferInMedia() - bufferedAfterReading
        // Paused although below it already: the load control said no there. A trigger for what already holds never
        // fires, so ask again once another second has played.
        if isPaused, let reading {
            let readingBuffered = bufferedAhead(of: reading)
            if readingBuffered < threshold {
                threshold = readingBuffered - Self.loadingRetryStep
            }
        }

        for period in periods {
            if isPaused, period === reading, threshold > .zero {
                // "Less than", as the load control compares: when it fires, the answer is yes.
                period.changeDurationForStartLoadingTriggerTokens(threshold, streamIndices: bufferStreamIndices) { [weak self] _ in
                    self?.requestPeriodsUpdate()
                }
            } else {
                period.changeDurationForStartLoadingTriggerTokens(nil)
            }
        }
    }

    private func bufferedAhead(of period: MediaPeriodHolder) -> CMTime {
        period.queuedAheadDuration(streamIndices: bufferStreamIndices) ?? .zero
    }

    /// The renderers whose streams measure the buffer: audio and video. Sparse media, like subtitles, holds little
    /// queued however much is loaded: its streams would keep the buffer looking empty, and never full.
    private var bufferStreamIndices: Set<Int>? {
        let indices = Set(renderers.indices.filter { [.audio, .video].contains(renderers[$0].trackType) })
        return indices.isEmpty ? nil : indices
    }

    /// The min buffer as `LoadControl.shouldContinueLoading` counts it, in media time: above 1x it
    /// grows with the speed, up to the max buffer. The trigger that restarts loading must use the
    /// same amount, or it fires while the load control still says no, and loading never restarts.
    private func minBufferInMedia() -> CMTime {
        let minBuffer = loadControl.getMinBufferDuration(playerId: identifier)
        let speed = mediaClock.getPlaybackParameters().playbackRate
        guard speed > 1 else {
            return max(minBuffer, .from(microseconds: 500_000))
        }
        let scaled = min(CMTimeMultiplyByFloat64(minBuffer, multiplier: Float64(speed)), loadControl.getMaxBufferDuration(playerId: identifier))
        return max(scaled, .from(microseconds: 500_000))
    }

    private func isLoadingPossible(mediaPeriodHolder: MediaPeriodHolder?) -> Bool {
        guard let mediaPeriodHolder else { return false }

        return mediaPeriodHolder.getNextLoadPosition() != .positiveInfinity
    }

    private func updateIsLoading() {
        let loadingPeriod = periodQueue.loading
        let isLoading = shouldContinueLoading || loadingPeriod?.mediaPeriod.isLoading ?? false
        if isLoading != playbackInfo.isLoading {
            SELogger.debug(.loadControl, "The player is \(isLoading ? "loading" : "not loading"), buffered to \(playbackInfo.bufferedPosition.seconds)")
            playbackInfo = playbackInfo.isLoading(isLoading)
            // Buffering ends once loading stops, even short of the buffer for playback. The player has
            // no timer to look again, so it looks now.
            if !isLoading, playbackInfo.state == .buffering {
                workQueue.requestUpdate()
            }
        }
    }

    private func handlePositionDiscontinuity(
        mediaPeriodId: MediaPeriodId,
        position: CMTime,
        requestedContentPosition: CMTime,
        discontinuityStartPosition: CMTime,
        reportDiscontinuity: Bool,
        discontinuityReason: DiscontinuityReason
    ) -> PlaybackInfo {
        deliverPendingMessageAtStartPositionRequired = deliverPendingMessageAtStartPositionRequired
            || position != playbackInfo.position
            || mediaPeriodId != playbackInfo.periodId

        resetPendingPauseAtEndOfPeriod()
        var trackGroupArray = playbackInfo.trackGroups
        var trackSelectorResult = playbackInfo.trackSelectorResult

        if mediaSourceList.isPrepared {
            let playingPeriodHolder = periodQueue.playing
            trackGroupArray = playingPeriodHolder?.trackGroups ?? .empty
            trackSelectorResult = playingPeriodHolder?.trackSelectorResults ?? emptyTrackSelectorResult

            if let playingPeriodHolder,
               playingPeriodHolder.info.requestedContentPosition != requestedContentPosition {
                playingPeriodHolder.info = playingPeriodHolder.info.copyWithRequestedContentPosition(requestedContentPosition)
            }
        } else if mediaPeriodId != playbackInfo.periodId {
            trackGroupArray = .empty
            trackSelectorResult = emptyTrackSelectorResult
        }
        if reportDiscontinuity {
            playbackInfoUpdate.setPositionDiscontinuity(discontinuityReason)
        }
        return playbackInfo.setPosition(
            periodId: mediaPeriodId,
            position: position,
            requestedContentPosition: requestedContentPosition,
            discontinuityStartPosition: discontinuityStartPosition,
            totalBufferedDuration: getTotalBufferedDuration(),
            trackGroups: trackGroupArray,
            trackSelectorResult: trackSelectorResult
        )
    }

    private func enableRenderers() throws {
        guard let readingPeriod = periodQueue.reading else {
            assertionFailure()
            return
        }
        try enableRenderers(
            rendererWasEnabledFlags: Array(
                repeating: false,
                count: renderers.count
            ),
            startPosition: readingPeriod.getStartPositionRendererTime()
        )
    }

    private func enableRenderers(rendererWasEnabledFlags: [Bool], startPosition: CMTime) throws {
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
                try enableRenderer(
                    periodHolder: readingMediaPeriod,
                    rendererIndex: index,
                    wasRendererEnabled: rendererWasEnabledFlags[index],
                    startPosition: startPosition
                )
            }
        }
    }

    private func enableRenderer(
        periodHolder: MediaPeriodHolder,
        rendererIndex: Int,
        wasRendererEnabled: Bool,
        startPosition: CMTime
    ) throws {
        let renderer = renderers[rendererIndex]
        guard !renderer.isRendererEnabled else { return }

        let playingAndReadingTheSamePeriod = periodQueue.playing === periodHolder
        let trackSelectorResult = periodHolder.trackSelectorResults
        guard let newSelection = trackSelectorResult.selections[rendererIndex],
              let sampleStream = periodHolder.sampleStreams[rendererIndex] else {
            return
        }

        let playing = shouldPlayWhenReady() && playbackInfo.state == .ready
        let joining = !wasRendererEnabled && playing
        enabledRendererCount += 1

        try renderer.enable(
            trackSelection: newSelection,
            stream: sampleStream,
            position: rendererPosition,
            joining: joining,
            mayRenderStartOfStream: playingAndReadingTheSamePeriod,
            startPosition: startPosition,
            offset: periodHolder.renderPositionOffset,
            mediaPeriodId: periodHolder.info.id,
            mediaClock: mediaClock,
            delegate: self
        )

        // Registered once: every renderer enable used to add another observer, so each consumed
        // buffer posted more and more `doSomeWork` messages as seeks and transitions went by.
        let bufferConsumed = Notification.Name(kCMSampleBufferConsumerNotification_BufferConsumed as String)
        NotificationCenter.default.removeObserver(self, name: bufferConsumed, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rendererDidReadSampleAtBoundaries),
            name: bufferConsumed,
            object: nil
        )

        if playing, playingAndReadingTheSamePeriod {
            try renderer.start()
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

        playbackInfo.bufferedPosition = if let loading {
            loading.getBufferedPosition()
        } else {
            playbackInfo.position
        }
        playbackInfo.totalBufferedDuration = getReportedTotalBufferedDuration()

        if loadingMediaPeriodChanged || loadingTrackSelectionChanged,
           let loading, loading.isPrepared {
            updateLoadControlTrackSelection(
                mediaPeriodId: loading.info.id,
                trackGroups: loading.trackGroups,
                trackSelectorResult: loading.trackSelectorResults
            )
        }
    }

    /// The buffered duration ahead of `playbackInfo.position`, which the player's public API counts from. The renderer
    /// position may have moved on since that position was published, and counting from it would take the time played
    /// meanwhile off twice.
    private func getReportedTotalBufferedDuration() -> CMTime {
        guard let loading = periodQueue.loading, let playing = periodQueue.playing else {
            return .zero
        }
        let bufferedPosition = loading.toRendererTime(periodTime: playbackInfo.bufferedPosition)
        return max(.zero, bufferedPosition - playing.toRendererTime(periodTime: playbackInfo.position))
    }

    private func getTotalBufferedDuration(bufferedPositionInLoadingPeriod: CMTime? = nil) -> CMTime {
        let bufferedPositionInLoadingPeriod = bufferedPositionInLoadingPeriod ?? playbackInfo.bufferedPosition
        guard let loadingPeriodHolder = periodQueue.loading else {
            return .zero
        }

        let totalBufferedDuration = bufferedPositionInLoadingPeriod - loadingPeriodHolder.toPeriodTime(rendererTime: rendererPosition)
        return max(.zero, totalBufferedDuration)
    }

    private func updateLoadControlTrackSelection(
        mediaPeriodId: MediaPeriodId,
        trackGroups: TrackGroupArray,
        trackSelectorResult: TrackSelectorResult
    ) {
        guard let loadingPeriodHolder = periodQueue.loading else {
            return
        }

        let playbackPosition = if loadingPeriodHolder == periodQueue.playing {
            loadingPeriodHolder.toPeriodTime(rendererTime: rendererPosition)
        } else {
            loadingPeriodHolder.toPeriodTime(rendererTime: rendererPosition) - loadingPeriodHolder.info.startPosition
        }

        let bufferedDuration = getTotalBufferedDuration(
            bufferedPositionInLoadingPeriod: loadingPeriodHolder.getBufferedPosition()
        )

        loadControl.onTracksSelected(
            parameters: LoadControlParams(
                playerId: identifier,
                timeline: playbackInfo.timeline,
                mediaPeriodId: mediaPeriodId,
                playbackPosition: playbackPosition,
                bufferedDuration: bufferedDuration,
                playbackSpeed: mediaClock.getPlaybackParameters().playbackRate,
                playWhenReady: playbackInfo.playWhenReady,
                rebuffering: isRebuffering,
                targetLiveOffset: targetLiveOffset(periodId: mediaPeriodId),
                lastRebufferRealtime: lastRebufferRealtime
            ),
            trackGroups: trackGroups,
            trackSelections: trackSelectorResult.selections
        )
    }

    func shouldPlayWhenReady() -> Bool {
        return playbackInfo.playWhenReady && playbackInfo.playbackSuppressionReason == .none
    }

    /// Throws the error of the stream a renderer reads from the playing period, if it can't provide more samples.
    ///
    /// A text or metadata track that fails doesn't stop playback: its renderer is disabled instead.
    private func maybeThrowRendererStreamError(rendererIndex: Int) throws {
        guard let playing = periodQueue.playing else { return }
        let renderer = renderers[rendererIndex]
        do {
            try renderer.maybeThrowStreamError(for: playing)
        } catch {
            switch renderer.trackType {
            case .text, .metadata:
                let current = playing.trackSelectorResults
                let format = current.selections[rendererIndex].map { "\($0.selectedFormat)" } ?? "none"
                SELogger.warning(.trackSelection, "Disabling track \(format) due to error: \(error)")
                var rendererConfigurations = current.rendererConfigurations
                var selections = current.selections
                rendererConfigurations[rendererIndex] = nil
                selections[rendererIndex] = nil
                let newResult = TrackSelectorResult(
                    rendererConfigurations: rendererConfigurations,
                    selections: selections,
                    tracks: current.tracks,
                    info: current.info
                )
                try disableRenderer(rendererIndex: rendererIndex)
                try playing.applyTrackSelection(
                    trackSelectorResult: newResult,
                    position: playbackInfo.position,
                    forceRecreateStreams: false
                )
            default:
                throw error
            }
        }
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
                periodPosition: .zero,
                requestedContentPosition: .invalid,
                forceBufferingState: false,
                endPlayback: true,
                setTargetLiveOffset: false
            )
        }

        let oldPeriodId = playbackInfo.periodId
        var newPeriodId = oldPeriodId.periodId
        let isUsingPlaceholderPeriod = isUsingPlaceholderPeriod(playbackInfo: playbackInfo, period: period)
        let oldContentPosition = isUsingPlaceholderPeriod ? playbackInfo.requestedContentPosition : playbackInfo.position
        var newContentPosition = oldContentPosition
        var startAtDefaultPositionWindowIndex: Int?
        var forceBufferingState = false
        var endPlayback = false
        var setTargetLiveOffset = false

        if let pendingInitialSeekPosition {
            if let (periodId, periodPosition) = resolveSeekPosition(
                timeline: timeline,
                seekPosition: pendingInitialSeekPosition,
                trySubsequentPeriods: true,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled,
                window: window,
                period: period
            ) {
                if !pendingInitialSeekPosition.windowPosition.isValid {
                    startAtDefaultPositionWindowIndex = timeline.periodById(periodId, period: period).windowIndex
                } else {
                    newPeriodId = periodId
                    newContentPosition = periodPosition
                    setTargetLiveOffset = true
                }
                forceBufferingState = playbackInfo.state == .ended
            } else {
                endPlayback = true
                startAtDefaultPositionWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
            }
        } else if playbackInfo.timeline.isEmpty {
            startAtDefaultPositionWindowIndex = timeline.firstWindowIndex(shuffleModeEnabled: shuffleModeEnabled)
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
        } else if !oldContentPosition.isValid {
            startAtDefaultPositionWindowIndex = timeline.periodById(newPeriodId, period: period).windowIndex
        } else if isUsingPlaceholderPeriod {
            playbackInfo.timeline.periodById(oldPeriodId.periodId, period: period)

            if playbackInfo.timeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex ==
                playbackInfo.timeline.indexOfPeriod(by: oldPeriodId.periodId) {
                let windowPosition = oldContentPosition + period.positionInWindow
                let windowIndex = timeline.periodById(newPeriodId, period: period).windowIndex
                let periodPosition = timeline.periodPosition(
                    window: window,
                    period: period,
                    windowIndex: windowIndex,
                    windowPosition: windowPosition
                )

                newPeriodId = periodPosition?.0
                newContentPosition = periodPosition?.1 ?? .zero
            }

            setTargetLiveOffset = true
        }

        var contentPositionForAdResolution = newContentPosition
        if let startAtDefaultPositionWindowIndex {
            let defaultPosition = timeline.periodPosition(
                window: window,
                period: period,
                windowIndex: startAtDefaultPositionWindowIndex,
                windowPosition: .invalid
            )
            newPeriodId = defaultPosition?.0
            contentPositionForAdResolution = defaultPosition?.1 ?? newContentPosition
            newContentPosition = .invalid
        }

        // TODO: ad
        let newPeriodUUID = periodQueue.resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
            timeline: timeline,
            periodId: newPeriodId,
            position: contentPositionForAdResolution
        )

        return PositionUpdateForPlaylistChange(
            periodId: newPeriodUUID,
            periodPosition: contentPositionForAdResolution,
            requestedContentPosition: newContentPosition,
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

    private func updateRebufferingState(isRebuffering: Bool, resetLastRebufferRealtime: Bool) {
        self.isRebuffering = isRebuffering
        self.lastRebufferRealtime = isRebuffering && !resetLastRebufferRealtime ? clock.time : .invalid
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
            let requestPosition: CMTime = if pendingMessageInfo.message.position.isPositiveInfinity {
                .invalid
            } else {
                pendingMessageInfo.message.position
            }

            let periodPosition = resolveSeekPosition(
                timeline: newTimeline,
                seekPosition: .init(
                    timeline: pendingMessageInfo.message.timeline,
                    windowIndex: pendingMessageInfo.message.mediaItemIndex,
                    windowPosition: requestPosition
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
                periodTime: periodPosition.periodPosition,
                periodUid: periodPosition.periodId
            )

            if pendingMessageInfo.message.position.isPositiveInfinity {
                resolvePendingMessageEndOfStreamPosition(timeline: newTimeline, messageInfo: pendingMessageInfo, window: window, period: period)
            }
            return true
        }

        guard let resolvedPeriodUid = pendingMessageInfo.resolvedPeriodUid,
              let index = newTimeline.indexOfPeriod(by: resolvedPeriodUid) else {
            return false
        }

        if pendingMessageInfo.message.position.isPositiveInfinity {
            resolvePendingMessageEndOfStreamPosition(timeline: newTimeline, messageInfo: pendingMessageInfo, window: window, period: period)
            return true
        }

        pendingMessageInfo.resolvedPeriodIndex = index
        previousTimeline.periodById(resolvedPeriodUid, period: period)
        if period.isPlaceholder,
           previousTimeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex == previousTimeline.indexOfPeriod(by: resolvedPeriodUid) {
            let windowPosition = pendingMessageInfo.resolvedPeriodTime + period.positionInWindow
            let windowIndex = newTimeline.periodById(resolvedPeriodUid, period: period).windowIndex
            if let (periodId, periodPosition) = newTimeline.periodPosition(window: window, period: period, windowIndex: windowIndex, windowPosition: windowPosition) {
                pendingMessageInfo.setResolvedPosition(
                    periodIndex: newTimeline.indexOfPeriod(by: periodId) ?? -1,
                    periodTime: periodPosition,
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

        let position = period.duration.isValid ? period.duration : .positiveInfinity
        messageInfo.setResolvedPosition(periodIndex: lastPeriodIndex, periodTime: position, periodUid: lastPeriodUid)
    }

    private func resolveSeekPosition(
        timeline: Timeline,
        seekPosition: SeekPosition,
        trySubsequentPeriods: Bool,
        repeatMode: RepeatMode,
        shuffleModeEnabled: Bool,
        window: Window,
        period: Period
    ) -> (periodId: AnyHashable, periodPosition: CMTime)? {
        guard !timeline.isEmpty else { return nil }

        let seekTimeline = !seekPosition.timeline.isEmpty ? seekPosition.timeline : timeline
        guard let (periodId, periodPosition) = seekTimeline.periodPosition(
            window: window,
            period: period,
            windowIndex: seekPosition.windowIndex,
            windowPosition: seekPosition.windowPosition
        ) else {
            return nil
        }

        if timeline.equals(to: seekTimeline) {
            return (periodId, periodPosition)
        }

        if timeline.indexOfPeriod(by: periodId) != nil {
            if seekTimeline.periodById(periodId, period: period).isPlaceholder,
               seekTimeline.getWindow(windowIndex: period.windowIndex, window: window).firstPeriodIndex == seekTimeline.indexOfPeriod(by: periodId) {
                let newWindowIndex = timeline.periodById(periodId, period: period).windowIndex

                return timeline.periodPosition(
                    window: window,
                    period: period,
                    windowIndex: newWindowIndex,
                    windowPosition: seekPosition.windowPosition
                )
            }

            return (periodId, periodPosition)
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
                return timeline.periodPosition(
                    window: window,
                    period: period,
                    windowIndex: newWindowIndex,
                    windowPosition: .invalid
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
}

extension SEPlayerImplInternal {
    func setVideoOutput(_ output: any VideoOutput) {
        post("setVideoOutput") { try $0.setVideoOutputInternal(output) }
    }

    func removeVideoOutput(_ output: any VideoOutput) {
        post("removeVideoOutput") { try $0.removeVideoOutputInternal(output) }
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
        let windowPosition: CMTime
    }

    private struct PositionUpdateForPlaylistChange {
        let periodId: MediaPeriodId
        let periodPosition: CMTime
        let requestedContentPosition: CMTime
        let forceBufferingState: Bool
        let endPlayback: Bool
        let setTargetLiveOffset: Bool
    }

    private final class PendingMessageInfo: Comparable {
        let message: PlayerMessage
        var resolvedPeriodIndex = 0
        var resolvedPeriodTime = CMTime.zero
        var resolvedPeriodUid: AnyHashable?

        init(message: PlayerMessage) {
            self.message = message
        }

        func setResolvedPosition(periodIndex: Int, periodTime: CMTime, periodUid: AnyHashable) {
            resolvedPeriodIndex = periodIndex
            resolvedPeriodTime = periodTime
            resolvedPeriodUid = periodUid
        }

        static func == (lhs: PendingMessageInfo, rhs: PendingMessageInfo) -> Bool {
            let lhsResolved = lhs.resolvedPeriodUid != nil
            let rhsResolved = rhs.resolvedPeriodUid != nil

            if lhsResolved != rhsResolved { return false }
            if !lhsResolved { return true }

            return lhs.resolvedPeriodIndex == rhs.resolvedPeriodIndex
            && lhs.resolvedPeriodTime == rhs.resolvedPeriodTime
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

            return lhs.resolvedPeriodTime < rhs.resolvedPeriodTime
        }
    }
}

private extension SEPlayerImplInternal {
    /// The longest a seek waits for the scrubbing seek in flight. Then it runs, and cancels it.
    static let maxScrubbingSeekWait = DispatchTimeInterval.seconds(2)
    /// How much more plays before loading that was refused below the min buffer is asked about again.
    static let loadingRetryStep = CMTime(value: 1, timescale: 1)
    /// How long playback may stay buffering with an almost empty buffer, and nothing loading, before it fails.
    static let playbackStuckTimeout = CMTime(value: 4, timescale: 1)
    /// How often the player looks again while buffering.
    static let bufferingWorkIntervalMs = 1000
    /// How long a renderer may stay not ready after a recovery rebuffer, with its media ready, before it is
    /// recovered again.
    static let rendererRecoveryTimeout = DispatchTimeInterval.seconds(5)
}
