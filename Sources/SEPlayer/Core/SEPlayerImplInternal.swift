//
//  SEPlayerImplInternal.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import AVFoundation

final class SEPlayerImplInternal: MediaSourceDelegate, MediaPeriodCallback, MediaSourceList.Delegate {
    @MainActor public let delegate = MulticastDelegate<SEPlayerDelegate>(isThreadSafe: false)

    public let identifier: UUID

    public var playbackRate: Float {
        get { queue.sync { playbackParams.playbackRate } }
        set { queue.async { self.updatePlaybackRate(new: newValue) } }
    }

    private let queue: Queue
    private let periodQueue: MediaPeriodQueue
    
    private let _dependencies: SEPlayerDependencies
    private let timer: DispatchSourceTimer
    
    private let emptyTrackSelectorResult: TrackSelectionResult
    
    private var playbackInfo: PlaybackInfo
    private var shouldContinueLoading: Bool = false

    private var playbackParams = PlaybackParameters.default
    private var rendererPositionUs = Int64.zero
    private var rendererPositionElapsedRealtime: Int64 = .zero

    public var isPlaying: Bool = false
    
    private var pendingInitialSeekPosition: SeekPosition?
    
    var clockLastTime = Int64.zero
    var isReady: Bool = false
    
    var started = false
    
    init(
        queue: Queue,
        renderers: [SERenderer],
        trackSelector: TrackSelector,
        emptyTrackSelectorResult: TrackSelectionResult,
        loadControl: LoadControl,
        repeatMode: SEPlayer.RepeatMode,
        shuffleModeEnabled: Bool,
        seekParameters: SeekParameters,
        pauseAtEndOfWindow: Bool,
        clock: CMClock,
        identifier: UUID,
        preloadConfiguration: PreloadConfiguration,
        bufferableContainer: PlayerBufferableContainer
    ) {
        self.queue = queue
        self.identifier = identifier

        _dependencies = SEPlayerDependencies(
            playerId: identifier,
            queue: queue,
            clock: clock,
            allocator: loadControl.getAllocator(),
            bufferableContainer: bufferableContainer
        )
        
        let mediaSourceList = _dependencies.mediaSourceList
        self.emptyTrackSelectorResult = emptyTrackSelectorResult

        periodQueue = MediaPeriodQueue(mediaPeriodBuilder: { info, positionUs in
            try MediaPeriodHolder(
                queue: queue,
                rendererCapabilities: renderers.map { $0.getCapabilities() },
                allocator: loadControl.getAllocator(),
                mediaSourceList: mediaSourceList,
                info: info,
                trackSelector: DefaultTrackSelector(),
                emptyTrackSelectorResult: emptyTrackSelectorResult,
                targetPreloadBufferDurationUs: .timeUnset
            )
        })

        playbackInfo = PlaybackInfo.dummy(
            clock: _dependencies.clock,
            emptyTrackSelectorResult: emptyTrackSelectorResult
        )
        self.timer = DispatchSource.makeTimerSource(queue: queue.queue)
        _dependencies.mediaSourceList.delegate = self
        setupTimer()
    }

    private func setState(_ state: SEPlayer.State) {
        guard playbackInfo.state != state else { return }
        // TODO: playbackMaybeBecameStuckAtMs
        playbackInfo = playbackInfo.playbackState(state)
    }

    func prepareInternal() {
        assert(queue.isCurrent())
        do {
            resetInternal(
                resetRenderers: false,
                resetPosition: false,
                releaseMediaSourceList: false,
                resetError: true
            )
            try _dependencies.mediaSourceList.prepare(mediaTransferListener: nil)
            setState(playbackInfo.timeline.isEmpty ? .ended : .buffering)
            timer.activate()
            timer.schedule(deadline: .now())
        } catch {
            
        }
    }

    func setMediaItemsInternal(info: MediaSourceListUpdateInfo) {
        if let windowIndex = info.windowIndex {
            pendingInitialSeekPosition = .init(
                timeline: PlaylistTimeline(
                    mediaSourceInfoHolders: info.mediaSourceHolders,
                    shuffleOrder: info.shuffleOrder
                ),
                windowIndex: windowIndex,
                windowPositionUs: info.positionUs
            )
        }

        let timeline = _dependencies.mediaSourceList.setMediaSource(
            holders: info.mediaSourceHolders,
            shuffleOrder: info.shuffleOrder
        )
        // TODO: handleMediaSourceListInfoRefreshed
    }

    func addMediaItemsInternal(
        holders: [MediaSourceList.MediaSourceHolder],
        shuffleOrder: ShuffleOrder,
        at index: Int
    ) {
        let timeline = _dependencies.mediaSourceList.addMediaSource(
            index: index,
            holders: holders,
            shuffleOrder: shuffleOrder
        )

        // TODO: handlerMediaSourceList
    }

    public func set(content: URL) {
        queue.async { [weak self] in
            self?._set(content: content)
        }
    }
    
    public func play() {
        queue.async { [self] in
            guard _dependencies.mediaPeriodHolder?.isPrepared == true else {
                return
            }
            if !isPlaying {
                timer.resume()
                isPlaying = true
            }
        }
    }
    
    public func pause() {
        queue.async { [self] in
            if isPlaying {
                timer.suspend()
                isReady = false
                isPlaying = false
                stopRenderers()
            }
        }
    }
    
    private func seekToCurrentPosition(sendDiscontinuity: Bool) throws {
        
    }
    
    private func startRenderers() throws {
        guard let playingPeriodHolder = periodQueue.playing else {
            return
        }
        let trackSelectorResult = playingPeriodHolder.trackSelectorResults
        for index in 0..<_dependencies.renderers.count {
            if !trackSelectorResult.isRendererEnabled(for: index) {
                continue
            }
            
            try _dependencies.renderers[index].start()
        }
    }
    
    private func stopRenderers() {
        _dependencies.standaloneClock.stop()
        _dependencies.renderers.forEach { $0.stop() }
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
                // TODO: handleLoadingMediaPeriodChanged
                maybeContinueLoading()
            }
            try resetRendererPosition(periodPositionUs: discontinuityPositionUs)
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
            rendererPositionUs = _dependencies.standaloneClock
                .syncAndGetPosition(isReadingAhead: playingPeriodHolder !== periodQueue.reading)
            let periodPositionUs = playingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs)
            playbackInfo = playbackInfo.positionUs(periodPositionUs)
        }

        if let loading = periodQueue.loading {
            playbackInfo.bufferedPositionUs = loading.getBufferedPositionUs()
            playbackInfo.totalBufferedDurationUs = getTotalBufferedDurationUs()
        }
    }
    
    
    
    
    
    func updatePeriods() throws {
        guard !playbackInfo.timeline.isEmpty || _dependencies.mediaSourceList.isPrepared else {
            return
        }
        let _ = try maybeUpdateLoadingPeriod()
        try maybeUpdatePrewarmingPeriod()
        try maybeUpdateReadingPeriod()
        try maybeUpdateReadingRenderers()
        try maybeUpdatePlayingPeriod()
//        try maybeUpdatePreloadPeriods(loadingPeriodChanged)
    }

    func maybeUpdateLoadingPeriod() throws -> Bool {
        let loadingPeriodChanged = false
        periodQueue.reevaluateBuffer(rendererPositionUs: rendererPositionUs)
        if periodQueue.shouldLoadNextMediaPeriod() {
            // TODO:
//            let info = periodQueue.
        }

        if shouldContinueLoading {
            self.shouldContinueLoading = isLoadingPossible(
                mediaPeriodHolder: periodQueue.loading
            )
            updateIsLoading()
        } else {
            maybeContinueLoading()
        }

        return loadingPeriodChanged
    }

    func maybeUpdatePrewarmingPeriod() throws {}
    func maybePrewarmRenderers() throws {}

    func maybeUpdateReadingPeriod() throws {
        guard let readingPeriodHolder = periodQueue.reading else {
            return
        }

        
    }

    func maybeUpdateReadingRenderers() throws {
        guard let readingPeriod = periodQueue.reading,
              periodQueue.playing !== readingPeriod,
              !readingPeriod.allRenderersInCorrectState else {
            return
        }

        if try updateRenderersForTransition() {
            readingPeriod.allRenderersInCorrectState = true
        }
    }

    private func updateRenderersForTransition() throws -> Bool {
        return true
    }

    func maybeUpdatePreloadPeriods(loadingPeriodChanged: Bool) {}

    func maybeUpdatePlayingPeriod() throws {
        
    }

    func getTotalBufferedDurationUs() -> Int64 {
        getTotalBufferedDurationUs(
            bufferedPositionInLoadingPeriodUs: playbackInfo.bufferedPositionUs
        )
    }

    func getTotalBufferedDurationUs(bufferedPositionInLoadingPeriodUs: Int64) -> Int64 {
        guard let loadingPeriodHolder = periodQueue.loading else {
            return .zero
        }

        let totalBufferedDurationUs = bufferedPositionInLoadingPeriodUs - loadingPeriodHolder.toPeriodTime(rendererTime: rendererPositionUs)
        return max(.zero, totalBufferedDurationUs)
    }

    private func resetRendererPosition(periodPositionUs: Int64) throws {
        let playingMediaPeriod = periodQueue.playing
        rendererPositionUs = if let playingMediaPeriod {
            playingMediaPeriod.toRendererTime(periodTime: periodPositionUs)
        } else {
            MediaPeriodQueue.initialRendererPositionOffsetUs + periodPositionUs
        }
        _dependencies.standaloneClock.resetPosition(position: periodPositionUs)
        try _dependencies.renderers.forEach { try $0.resetPosition(new: rendererPositionUs) }
        // TODO: notifyTrackSelectionDiscontinuity
    }

    private func handlePositionDiscontinuity(
        mediaPeriodId: MediaPeriodId,
        positionUs: Int64,
        requestedContentPositionUs: Int64,
        discontinuityStartPositionUs: Int64,
        reportDiscontinuity: Bool,
        discontinuityReason: SEPlayer.DiscontinuityReason
    ) -> PlaybackInfo {
        // TODO: resetPendingPauseAtEndOfPeriod()
        var trackGroups = playbackInfo.trackGroups
        var trackSelectorResult = playbackInfo.trackSelectorResult

        if _dependencies.mediaSourceList.isPrepared {
            let playingPeriodHolder = periodQueue.playing
            trackGroups = playingPeriodHolder?.trackGroups ?? []
            trackSelectorResult = playingPeriodHolder?.trackSelectorResults ?? emptyTrackSelectorResult

            if let playingPeriodHolder,
               playingPeriodHolder.info.requestedContentPositionUs != requestedContentPositionUs {
                playingPeriodHolder.info = playingPeriodHolder.info.copyWithStartPositionUs(requestedContentPositionUs)
            }
        } else if mediaPeriodId != playbackInfo.periodId {
            trackGroups = []
            trackSelectorResult = emptyTrackSelectorResult
        }

        return playbackInfo.positionUs(
            periodId: mediaPeriodId,
            positionUs: positionUs,
            requestedContentPositionUs: requestedContentPositionUs,
            discontinuityStartPositionUs: discontinuityStartPositionUs,
            totalBufferedDurationUs: getTotalBufferedDurationUs(),
            trackGroups: trackGroups,
            trackSelectorResult: trackSelectorResult
        )
    }
}

private extension SEPlayerImplInternal {
    func _set(content: URL) {
//        assert(queue.isCurrent())
//        let loaderQueue = SignalQueue(name: "com.seplayer.loader_\(identifier)", qos: .userInteractive)
//        let dataSource = RangeRequestHTTPDataSource(
//            queue: Queues.loaderQueue,
//            networkLoader: _dependencies.sessionLoader
//        )
//        let progressiveMediaExtractor = BundledMediaExtractor(
//            queue: loaderQueue,
//            extractorQueue: loaderQueue
//        )
//
//        let mediaSource = ProgressiveMediaSource(
//            queue: queue,
//            loaderQueue: loaderQueue,
//            mediaItem: .init(url: content),
//            dataSource: dataSource,
//            progressiveMediaExtractor: progressiveMediaExtractor,
//            continueLoadingCheckIntervalBytes: 1024 * 1024
//        )
//        _dependencies.mediaSource = mediaSource
//
//        
////        let mediaPeriodHolder = MediaPeriodHolder(
////            queue: queue,
////            rendererCapabilities: <#T##[any RendererCapabilities]#>,
////            allocator: _dependencies.allocator,
////            mediaSourceList: _dependencies.mediaSourceList,
////            info: <#T##MediaPeriodInfo#>,
////            trackSelector: <#T##any TrackSelector#>,
////            emptyTrackSelectorResult: <#T##TrackSelectionResult#>,
////            targetPreloadBufferDurationUs: <#T##Int64#>)
////
//////        let mediaSourceList = MediaSourceList(playerId: identifier)
//////        mediaSourceList.setMediaSource(holders: [.init(mediaSource: mediaSource)])
//////
//////        let mediaPeriodHolder = MediaPeriodHolder(
//////            queue: queue,
//////            rendererCapabilities: _dependencies.renderers.map { $0.getCapabilities() },
//////            allocator: _dependencies.allocator,
//////            mediaSourceList: mediaSourceList,
//////            info: .init(
//////                id: .init(periodId: UUID(), windowSequenceNumber: 0), startPositionUs: .zero, requestedContentPositionUs: .zero, endPositionUs: .zero, durationUs: .zero, isFinal: false
//////            ),
//////            trackSelector: DefaultTrackSelector(),
//////            emptyTrackSelectorResult: emptyTrackSelectorResult
//////        )
//////        mediaPeriodHolder.renderPositionOffset = rendererPositionUs
//////        _dependencies.mediaPeriodHolder = mediaPeriodHolder
//////        mediaPeriodHolder.prepare(callback: self, on: .zero)
    }

    private func maybeContinueLoading() {
        if shouldContinueLoadingPeriod(), let loadingPeriod = periodQueue.loading {
            loadingPeriod.continueLoading(loadingInfo: .init(
                playbackPosition: loadingPeriod.toPeriodTime(rendererTime: rendererPositionUs),
                playbackSpeed: _dependencies.standaloneClock.getPlaybackParameters().playbackRate,
                lastRebufferRealtime: .zero
            ))
        }
        updateIsLoading()
    }

    private func shouldContinueLoadingPeriod() -> Bool {
        guard let loadingPeriod = periodQueue.loading, isLoadingPossible(mediaPeriodHolder: loadingPeriod) else {
            return false
        }
//        _dependencies.
        return true
    }

    private func isLoadingPossible(mediaPeriodHolder: MediaPeriodHolder?) -> Bool {
        guard let mediaPeriodHolder else { return false }

        return mediaPeriodHolder.getNextLoadPosition() != .timeUnset
    }

    private func updateIsLoading() {}
}

extension SEPlayerImplInternal {
    func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline) {
        assert(queue.isCurrent())
    }
}

extension SEPlayerImplInternal {
    func didPrepare(mediaPeriod: any MediaPeriod) {
        assert(queue.isCurrent())
        do {
            if periodQueue.isLoading(mediaPeriod: mediaPeriod) {
                guard let loadingPeriod = periodQueue.loading else {
                    return
                }
                try handleLoadingPeriodPrepared(loadingPeriodHolder: loadingPeriod)
            } else {
                guard let preloadHolder = periodQueue.preloading,
                      preloadHolder.isPrepared else {
                    return
                }
                
                preloadHolder.handlePrepared(
                    playbackSpeed: playbackInfo.playbackParameters.playbackRate,
                    timeline: playbackInfo.timeline,
                    playWhenReady: playbackInfo.playWhenReady
                )
                if periodQueue.isPreloading(mediaPeriod: mediaPeriod) {
                    // TODO: maybeContinuePreloading()
                }
            }
        } catch {
            // TODO: handle error
        }
    }

    private func handleLoadingPeriodPrepared(loadingPeriodHolder: MediaPeriodHolder) throws {
        if !loadingPeriodHolder.isPrepared {
            loadingPeriodHolder.handlePrepared(
                playbackSpeed: playbackInfo.playbackParameters.playbackRate,
                timeline: playbackInfo.timeline,
                playWhenReady: playbackInfo.playWhenReady
            )
        }

        if loadingPeriodHolder === periodQueue.playing {
            try resetRendererPosition(periodPositionUs: loadingPeriodHolder.info.startPositionUs)
            try enableRenderers()
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

    func continueLoadingRequested(with source: any MediaPeriod) {
        assert(queue.isCurrent())
        maybeContinueLoading()
    }
}

extension SEPlayerImplInternal {
    func playlistUpdateRequested() {
        
    }
}

private extension SEPlayerImplInternal {
    private func setupTimer() {
        timer.setEventHandler { [weak self] in
            self?.doSomeWork()
        }
    }

    private func doSomeWork() {
        assert(queue.isCurrent())
        let currentTime = DispatchTime.now()

        do {
            try updatePeriods()

            guard playbackInfo.state != .idle || playbackInfo.state != .ended else {
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
                let rendererPositionElapsedRealtimeUs = _dependencies.clock.microseconds
                // TODO: playingPeriodHolder.mediaPeriod.discardBuffer(
//                    to: playbackInfo.positionUs - backBufferDurationUs,
//                    toKeyframe: retainBackBufferFromKeyframe
//                )
                for renderer in _dependencies.renderers {
                    try renderer.render(position: rendererPositionUs, elapsedRealtime: rendererPositionElapsedRealtimeUs)
                    renderersEnded = renderersEnded && renderer.isEnded()
                    let allowsPlayback = renderer.didReadStreamToEnd()
                        || renderer.isReady()
                        || renderer.isEnded()

                    renderersAllowPlayback = renderersAllowPlayback && allowsPlayback
                }
            } else {
                // TODO: maybe throw error
            }

            let playingPeriodDurationUs = playingPeriodHolder.info.durationUs
            let finishedRendering = renderersEnded
                && playingPeriodHolder.isPrepared
                && (playingPeriodDurationUs == .timeUnset || playingPeriodDurationUs <= playbackInfo.positionUs)

            if finishedRendering /* TODO: pendingPauseAtEndOfPeriod */{
                
            }

            if finishedRendering && playingPeriodHolder.info.isFinal {
                setState(.ended)
                stopRenderers()
            } else if playbackInfo.state == .buffering, shouldTransitionToReadyState(renderersReady: renderersAllowPlayback) {
                setState(.ready)
                if playbackInfo.playWhenReady {
//                    updateRe
                    _dependencies.standaloneClock.start()
                    try startRenderers()
                }
            } else if playbackInfo.state == .ready, !renderersAllowPlayback {
                setState(.buffering)
                stopRenderers()
            }
        } catch {
            fatalError()
        }

        timer.schedule(deadline: currentTime + .milliseconds(10))
    }

    private func scheduleNextWork(operationStartTime: DispatchTime) {
        // TODO: scheduleNextWork
    }

    func resetInternal(
        resetRenderers: Bool,
        resetPosition: Bool,
        releaseMediaSourceList: Bool,
        resetError: Bool
    ) {
        timer.suspend()
        _dependencies.standaloneClock.stop()
        rendererPositionUs = MediaPeriodQueue.initialRendererPositionOffsetUs
//        disableRenderers
        if resetRenderers {
            _dependencies.renderers.forEach { $0.reset() }
        }
//        enabledRendererCount = 0
    }

    private func shouldTransitionToReadyState(renderersReady: Bool) -> Bool {
        // TODO: shouldTransitionToReadyState
        return false
    }

    private func enableRenderers() throws {
        guard let readingPeriod = periodQueue.reading else {
            assertionFailure()
            return
        }
        try enableRenderers(
            rendererWasEnabledFlags: Array(
                repeating: false,
                count: _dependencies.renderers.count
            ),
            startPositionUs: readingPeriod.getStartPositionRenderTime()
        )
    }

    private func enableRenderers(rendererWasEnabledFlags: [Bool], startPositionUs: Int64) throws {
        guard let readingMediaPeriod = periodQueue.reading else {
            return
        }
        let trackSelectorResult = readingMediaPeriod.trackSelectorResults
        for (index, renderer) in _dependencies.renderers.enumerated() {
            if !trackSelectorResult.isRendererEnabled(for: index) {
                renderer.reset()
            }
        }
        for (index, renderer) in _dependencies.renderers.enumerated() {
            if trackSelectorResult.isRendererEnabled(for: index),
               renderer.getStream() !== readingMediaPeriod.sampleStreams[index] {
                try enableRenderer(
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
        let renderer = _dependencies.renderers[rendererIndex]
        guard renderer.getState() == .disabled, let sampleStream = periodHolder.sampleStreams[rendererIndex] else {
            return
        }

        let playingAndReadingTheSamePeriod = periodQueue.playing === periodHolder
        let trackSelectorResult = periodHolder.trackSelectorResults
//        let rendererConfiguration = trackSelectorResult.renderersConfig[rendererIndex]
//        let newSelection = trackSelectorResult.selections[rendererIndex]

        let playing = /* TODO: shouldPlayWhenReady()*/ playbackInfo.state == .ready
        let joining = !wasRendererEnabled && playing

        let formats = trackSelectorResult.selections
            .compactMap { $0 }
            .map { selection in
                (0..<selection.trackGroup.length).map { index in
                    selection.format(for: index)
                }
            }
            .flatMap { $0 }

        try renderer.enable(
            formats: formats,
            stream: sampleStream,
            position: rendererPositionUs,
            joining: joining,
            mayRenderStartOfStream: playingAndReadingTheSamePeriod,
            startPosition: startPositionUs,
            offset: periodHolder.renderPositionOffset,
            mediaPeriodId: periodHolder.info.id
        )

        if playing, playingAndReadingTheSamePeriod {
            try renderer.start()
        }
    }

//    private func stopRenderers() {
//        _dependencies.standaloneClock.stop()
//        _dependencies.renderers.forEach { $0.stop() }
//    }

    private func updatePlaybackRate(new playbackRate: Float) {
        assert(queue.isCurrent())
        let old = playbackParams
        self.playbackParams = PlaybackParameters(playbackRate: playbackRate)
        _dependencies.standaloneClock.setPlaybackParameters(new: playbackParams)
        _dependencies.renderers.forEach {
            try? $0.setPlaybackSpeed(current: old.playbackRate, target: playbackParams.playbackRate)
        }
    }
}

extension SEPlayerImplInternal {
    @MainActor func register(_ bufferable: PlayerBufferable) {
        _dependencies.bufferableContainer.register(bufferable)
    }

    @MainActor func remove(_ bufferable: PlayerBufferable) {
        _dependencies.bufferableContainer.remove(bufferable)
    }
}

extension SEPlayerImplInternal {
    static func resolveSubsequentPeriod(
        window: inout Window,
        period: inout Period,
        repeatMode: SEPlayer.RepeatMode,
        shuffleModeEnabled: Bool,
        oldPeriodId: AnyHashable,
        oldTimeline: Timeline,
        newTimeline: Timeline
    ) -> Int? {
        fatalError()
    }
}

struct SeekPosition {
    let timeline: Timeline
    let windowIndex: Int
    let windowPositionUs: Int64
}

struct MediaSourceListUpdateInfo {
    let mediaSourceHolders: [MediaSourceList.MediaSourceHolder]
    let shuffleOrder: ShuffleOrder
    let windowIndex: Int?
    let positionUs: Int64
}

struct MoveMediaItemsInfo {
    let range: Range<Int>
    let newIndex: Int
    let shuffleOrder: ShuffleOrder
}
