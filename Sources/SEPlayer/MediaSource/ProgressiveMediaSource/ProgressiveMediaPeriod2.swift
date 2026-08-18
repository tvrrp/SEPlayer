//
//  ProgressiveMediaPeriod2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.08.2026.
//

import CoreMedia
import DataSource
import Decoder
import Foundation
import Extractor
import os
import SEPlayerCommon

// MARK: - Lock

/// Replace with `Synchronization.Mutex` if the deployment target allows it; the API is identical.
/// `os_unfair_lock` is used deliberately: `readData`/`skipData` run on renderer/audio threads and
/// need priority donation from the lock.
public final class UnfairMutex<Value>: @unchecked Sendable {
    private var value: Value
    private let unfairLock: UnsafeMutablePointer<os_unfair_lock_s>

    public init(_ value: Value) {
        self.value = value
        self.unfairLock = .allocate(capacity: 1)
        self.unfairLock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inline(__always)
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return try body(&value)
    }
}

// MARK: -

/// Thread safety contract
/// ----------------------
/// All mutable state lives in `State` behind `stateLock`. The lock is the *outermost* lock in the
/// subsystem; `SampleQueue`, `Loader` and `AsyncConditionVariable` are leaf locks and may be called
/// while it is held. This requires:
///
///   1. `Loader` never invokes `Loader.Callback` synchronously from `startLoading`/`cancelLoading`/
///      `release`, and never holds its internal lock across a callback invocation.
///   2. `SampleQueue` is internally thread-safe (the extractor writes through `TrackOutput` while
///      renderers read through `SampleStream`), and invokes `SampleQueueDelegate` *outside* its own
///      lock — `didChange(format:)` re-enters `getUpstreamFormat()` on the same queue.
///   3. `AsyncConditionVariable` never calls back into this type.
///
/// Calls *up* (`MediaPeriodCallback`, `Listener`) are never made under the lock. They are buffered
/// as `Effect`s inside the critical section and flushed through `eventDispatch` after unlock.
final class ProgressiveMediaPeriod2: MediaPeriod {
    protocol Listener: AnyObject {
        func sourceInfoRefreshed(duration: CMTime, seekMap: SeekMap, isLive: Bool)
    }

    /// Delivery policy for upward callbacks. Defaults to the queue passed at init so existing
    /// call sites keep playback-thread delivery. Pass `{ $0() }` for inline delivery on the
    /// calling thread if the callback owner is itself thread-safe.
    typealias EventDispatch = (@escaping () -> Void) -> Void

    var trackGroups: TrackGroupArray { stateLock.withLock { $0.trackState.tracks } }

    /// Advisory: the conjunction is not atomic. Neither was the original.
    var isLoading: Bool { loader.isLoading() && loadCondition.isOpen }

    private let url: URL
    private let queue: Queue
    private let loaderSyncActor: PlayerActor
    private let dataSourceFactory: DataSourceFactory
    private weak var listener: Listener?
    private let allocator: Allocator
    private let continueLoadingCheckIntervalBytes: Int
    private let loader: Loader
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let loadCondition: AsyncConditionVariable
    private let eventDispatch: EventDispatch

    private let stateLock = UnfairMutex(State())

    init(
        url: URL,
        queue: Queue,
        loadQueue: Queue,
        dataSourceFactory: DataSourceFactory,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        listener: Listener,
        allocator: Allocator,
        continueLoadingCheckIntervalBytes: Int,
        eventDispatch: EventDispatch? = nil
    ) {
        self.url = url
        self.queue = queue
        self.loaderSyncActor = loadQueue.playerActor()
        self.dataSourceFactory = dataSourceFactory
        self.loader = Loader(workQueue: queue, loadQueue: loadQueue)
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.loadCondition = AsyncConditionVariable()
        self.listener = listener
        self.allocator = allocator
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        self.eventDispatch = eventDispatch ?? { work in queue.async { work() } }
    }

    // MARK: - MediaPeriod

    func release() {
        let queues: [SampleQueue] = stateLock.withLock { state in
            guard !state.didRelease else { return [] }
            state.didRelease = true
            state.callback = nil
            let queues = state.isPrepared ? state.sampleQueues : []
            state.seekMap = nil
            return queues
        }

        do {
            try queues.forEach { try $0.preRelease() }
        } catch {
            fatalError()
        }

        loader.release { [weak self] in
            self?.onLoaderReleased()
        }
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        stateLock.withLock { state in
            state.callback = callback
            _ = loadCondition.open()
            startLoading(&state)
        }
    }

    func maybeThrowPrepareError() throws {
        try maybeThrowError()
        try stateLock.withLock { state in
            if state.loadingFinished, !state.isPrepared {
                throw ParserError.createForMalformedContainer(
                    message: "Loading finished before preparation is complete."
                )
            }
        }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) throws -> CMTime {
        try withState { state, _ in
            assertPrepared(state)
            var position = position
            let tracks = state.trackState.tracks
            var trackEnabledStates = state.trackState.trackEnabledState
            let oldEnabledTrackCount = state.enabledTrackCount

            for index in 0..<selections.count {
                if streams[index] != nil, selections[index] == nil || !mayRetainStreamFlags[index] {
                    let track = (streams[index] as! SampleStreamHolder).track
                    assert(trackEnabledStates[track])
                    state.enabledTrackCount -= 1
                    // FIX: was `trackEnabledStates[index]`.
                    trackEnabledStates[track] = false
                    streams[index] = nil
                }
            }

            var seekRequired = state.seenFirstTrackSelection
                ? oldEnabledTrackCount == 0
                : position != .zero

            for (index, selection) in selections.enumerated() {
                guard let selection, streams[index] == nil else { continue }
                guard let trackIndex = tracks.firstIndex(of: selection.trackGroup) else {
                    streams[index] = nil
                    continue
                }

                streams[index] = SampleStreamHolder(track: trackIndex, handlers: makeStreamHandlers())
                state.enabledTrackCount += 1
                // FIX: was `trackEnabledStates[index]`.
                trackEnabledStates[trackIndex] = true
                streamResetFlags[index] = true

                if !seekRequired {
                    // FIX: was `sampleQueues[index]`.
                    let sampleQueue = state.sampleQueues[trackIndex]
                    seekRequired = sampleQueue.getReadIndex() != 0
                        && !sampleQueue.seek(time: position, allowTimeBeyondBuffer: true)
                }
            }

            if state.enabledTrackCount == 0 {
                state.pendingDeferredRetry = false
                state.notifyDiscontinuity = false
                state.pendingInitialDiscontinuity = false
                let queues = state.sampleQueues
                if loader.isLoading() {
                    try queues.forEach { try $0.discardToEnd() }
                    loader.cancelLoading()
                } else {
                    state.loadingFinished = false
                    try queues.forEach { try $0.reset() }
                }
            } else if seekRequired {
                position = try seek(&state, position: position)
                for index in 0..<streams.count where streams[index] != nil {
                    streamResetFlags[index] = true
                }
            }

            state.trackState.trackEnabledState = trackEnabledStates
            state.seenFirstTrackSelection = true
            return position
        }
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) throws {
        try stateLock.withLock { state in
            assertPrepared(state)
            guard !isPendingReset(state) else { return }

            let trackEnabledStates = state.trackState.trackEnabledState
            for (index, sampleQueue) in state.sampleQueues.enumerated() {
                try sampleQueue.discard(
                    toTime: position,
                    to: toKeyframe,
                    stopAtReadPosition: trackEnabledStates[index]
                )
            }
        }
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        stateLock.withLock { state in
            if state.loadingFinished
                || state.pendingDeferredRetry
                || (state.isPrepared && state.enabledTrackCount == 0) {
                return false
            }

            var continuedLoading = loadCondition.open()
            if !loader.isLoading() {
                startLoading(&state)
                continuedLoading = true
            }
            return continuedLoading
        }
    }

    func stopLoading() {
        stateLock.withLock { state in
            if !loader.isLoading()
                || !state.isPrepared
                || (state.isPrepared && state.enabledTrackCount == 0) {
                return
            }
            loadCondition.close()
        }
    }

    func getNextLoadPosition() -> CMTime {
        getBufferedPosition()
    }

    func readDiscontinuity() -> CMTime {
        stateLock.withLock { state in
            if state.pendingInitialDiscontinuity {
                state.pendingInitialDiscontinuity = false
                return state.lastSeekPosition
            }

            if state.notifyDiscontinuity,
               state.loadingFinished
                || getExtractedSamplesCount(state) > state.extractedSamplesCountAtStartOfLoad {
                state.notifyDiscontinuity = false
                return state.lastSeekPosition
            }

            return .invalid
        }
    }

    func getBufferedPosition() -> CMTime {
        stateLock.withLock { state in
            assertPrepared(state)
            if state.loadingFinished || state.enabledTrackCount == 0 {
                return .positiveInfinity
            } else if isPendingReset(state) {
                return state.pendingResetPosition
            }

            var largestQueuedTimestamp = CMTime.positiveInfinity
            if state.haveAudioVideoTracks {
                for (index, sampleQueue) in state.sampleQueues.enumerated() {
                    if state.trackState.isAudioOrVideo[index],
                       state.trackState.trackEnabledState[index],
                       !sampleQueue.lastSampleQueued() {
                        largestQueuedTimestamp = min(
                            largestQueuedTimestamp,
                            sampleQueue.getLargestQueuedTimestamp()
                        )
                    }
                }
            }

            if largestQueuedTimestamp.isPositiveInfinity {
                largestQueuedTimestamp = getLargestQueuedTimestamp(state, includeDisabledTracks: false)
            }

            return largestQueuedTimestamp.isNegativeInfinity
                ? state.lastSeekPosition
                : largestQueuedTimestamp
        }
    }

    func seek(position: CMTime) throws -> CMTime {
        try stateLock.withLock { state in
            try seek(&state, position: position)
        }
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        stateLock.withLock { state in
            assertPrepared(state)
            guard let seekMap = state.seekMap, seekMap.isSeekable() else { return .zero }

            let seekPoints = seekMap.getSeekPoints(for: position)
            return seekParameters.resolveSyncPosition(
                position: position,
                firstSync: seekPoints.first.time,
                secondSync: seekPoints.second.time
            )
        }
    }

    // MARK: - SampleStream plumbing

    func bufferedAheadDuration(track: Int) -> CMTime {
        stateLock.withLock { $0.sampleQueues[track].bufferedAheadDuration }
    }

    func isReady(track: Int) -> Bool {
        stateLock.withLock { state in
            !suppressRead(state) && state.sampleQueues[track].isReady(loadingFinished: state.loadingFinished)
        }
    }

    func maybeThrowError(sampleQueueIndex: Int) throws {
        let sampleQueue = stateLock.withLock { $0.sampleQueues[sampleQueueIndex] }
        try sampleQueue.maybeThrowError()
        try maybeThrowError()
    }

    func maybeThrowError() throws {
        try loader.maybeThrowError() // TODO: min retry count
    }

    func readData(track: Int, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        try withState { state, effects in
            guard !suppressRead(state) else { return .nothingRead }
            maybeNotifyDownstreamFormat(&state, track: track)

            let result = try state.sampleQueues[track].read(
                readFlags: readFlags,
                loadingFinished: state.loadingFinished
            )

            if result == .nothingRead {
                try maybeStartDeferredRetry(&state, track: track, effects: &effects)
            }

            return result
        }
    }

    func skipData(track: Int, position time: CMTime) throws -> Int {
        try withState { state, effects in
            guard !suppressRead(state) else { return .zero }

            maybeNotifyDownstreamFormat(&state, track: track)
            let sampleQueue = state.sampleQueues[track]
            let skipCount = sampleQueue.getSkipCount(time: time, allowEndOfQueue: state.loadingFinished)
            sampleQueue.skip(count: skipCount)
            if skipCount == 0 {
                try maybeStartDeferredRetry(&state, track: track, effects: &effects)
            }

            return skipCount
        }
    }

    func installTrigger(
        track: Int,
        condition: TriggerCondition,
        _ body: ((QueueTriggerToken) -> Void)?
    ) -> QueueTriggerToken {
        let sampleQueue = stateLock.withLock { $0.sampleQueues[track] }
        return sampleQueue.installTrigger(condition: condition, body)
//        stateLock.withLock { $0.sampleQueues[track].installTrigger(condition: condition, body) }
    }

    func removeTrigger(track: Int, token: QueueTriggerToken) {
        let sampleQueue = stateLock.withLock { $0.sampleQueues[track] }
        sampleQueue.removeTrigger(token)
//        stateLock.withLock { $0.sampleQueues[track].removeTrigger(token) }
    }

    func testTrigger(track: Int, token: QueueTriggerToken) -> Bool {
        let sampleQueue = stateLock.withLock { $0.sampleQueues[track] }
        return sampleQueue.testTrigger(token)
    }
}

// MARK: - Locked implementation

private extension ProgressiveMediaPeriod2 {
    func seek(_ state: inout State, position: CMTime) throws -> CMTime {
        assertPrepared(state)
        guard let seekMap = state.seekMap else { return .zero }
        let trackIsAudioVideoFlags = state.trackState.isAudioOrVideo
        let position = seekMap.isSeekable() ? position : .zero

        state.notifyDiscontinuity = false
        let isSameAsLastSeekPosition = state.lastSeekPosition == position
        state.lastSeekPosition = position

        if isPendingReset(state) {
            state.pendingResetPosition = position
            return position
        }

        if state.loadingFinished || loader.isLoading(),
           seekInsideBuffer(
               state,
               isAudioOrVideo: trackIsAudioVideoFlags,
               position: position,
               isSameAsLastSeekPosition: isSameAsLastSeekPosition
           ) {
            return position
        }

        state.pendingDeferredRetry = false
        state.pendingResetPosition = position
        state.loadingFinished = false
        state.pendingInitialDiscontinuity = false

        let queues = state.sampleQueues
        if loader.isLoading() {
            try queues.forEach { try $0.discardToEnd() }
            loader.cancelLoading()
        } else {
            try queues.forEach { try $0.reset() }
        }

        return position
    }

    func startLoading(_ state: inout State) {
        let loadable = ExtractingLoadable(
            url: url,
            syncActor: loaderSyncActor,
            dataSourceFactory: dataSourceFactory,
            progressiveMediaExtractor: progressiveMediaExtractor,
            extractorOutput: self,
            loadCondition: loadCondition,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes,
            requestContiniueLoading: { [weak self] in
                self?.withState { _, effects in effects.append(.continueLoadingRequested) }
            }
        )

        if state.isPrepared {
            guard let seekMap = state.seekMap else { return }

            if state.duration.isValid, state.pendingResetPosition > state.duration {
                state.loadingFinished = true
                state.pendingResetPosition = .invalid
                return
            }

            let pendingResetPosition = state.pendingResetPosition
            let seekPoints = seekMap.getSeekPoints(for: pendingResetPosition)
            loadable.setLoadPosition(position: seekPoints.first.position, time: pendingResetPosition)
            state.sampleQueues.forEach { $0.setStartTime(pendingResetPosition) }
            state.pendingResetPosition = .invalid
        }

        state.extractedSamplesCountAtStartOfLoad = getExtractedSamplesCount(state)
        loader.startLoading(loadable: loadable, callback: self, defaultMinRetryCount: 3)
    }

    func configureRetry(
        _ state: inout State,
        loadable: ExtractingLoadable,
        currentExtractedSampleCount: Int
    ) throws -> Bool {
        if state.isLengthKnown || state.seekMap?.getDuration().isValid == true {
            // On-demand stream: resume the current loadable from where it left off.
            state.extractedSamplesCountAtStartOfLoad = currentExtractedSampleCount
            return true
        } else if state.isPrepared, !suppressRead(state) {
            state.pendingDeferredRetry = true
            return false
        } else {
            state.notifyDiscontinuity = state.isPrepared
            state.lastSeekPosition = .zero
            state.extractedSamplesCountAtStartOfLoad = 0
            try state.sampleQueues.forEach { try $0.reset() }
            loadable.setLoadPosition(position: 0, time: .zero)
            return true
        }
    }

    func maybeStartDeferredRetry(
        _ state: inout State,
        track: Int,
        effects: inout [Effect]
    ) throws {
        assertPrepared(state)
        if !state.pendingDeferredRetry
            || (state.haveAudioVideoTracks && !state.trackState.isAudioOrVideo[track])
            || state.sampleQueues[track].isReady(loadingFinished: false) {
            return
        }

        state.pendingResetPosition = .zero
        state.pendingDeferredRetry = false
        state.notifyDiscontinuity = true
        state.lastSeekPosition = .zero
        state.extractedSamplesCountAtStartOfLoad = 0

        try state.sampleQueues.forEach { try $0.reset() }
        effects.append(.continueLoadingRequested)
    }

    func maybeNotifyDownstreamFormat(_ state: inout State, track: Int) {
    }

    func suppressRead(_ state: State) -> Bool {
        state.notifyDiscontinuity || isPendingReset(state)
    }

    func prepareTrackOutput(_ state: inout State, id: Int) throws -> TrackOutput {
        for index in 0..<state.sampleQueues.count where id == state.sampleQueueTrackIds[index] {
            return state.sampleQueues[index]
        }

        let trackOutput = try SampleQueue(queue: queue)
        trackOutput.delegate = self
        state.sampleQueueTrackIds.append(id)
        state.sampleQueues.append(trackOutput)
        return trackOutput
    }

    func setSeekMap(_ state: inout State, seekMap: SeekMap, effects: inout [Effect]) {
        state.duration = seekMap.getDuration()
        state.seekMap = seekMap
        if state.isPrepared {
            effects.append(
                .sourceInfoRefreshed(duration: state.duration, seekMap: seekMap, isLive: false)
            )
        } else {
            maybeFinishPrepare(&state, effects: &effects)
        }
    }

    func maybeFinishPrepare(_ state: inout State, effects: inout [Effect]) {
        guard !state.didRelease, !state.isPrepared, state.sampleQueuesBuild,
              let seekMap = state.seekMap else { return }

        for sampleQueue in state.sampleQueues where sampleQueue.getUpstreamFormat() == nil {
            return
        }

        loadCondition.close()
        var trackGroups: [TrackGroup] = []
        var isAudioOrVideo: [Bool] = []

        for index in 0..<state.sampleQueues.count {
            guard let format = state.sampleQueues[index].getUpstreamFormat() else { continue }

            do {
                // NOTE: a `continue` here desynchronizes trackGroup indices from sampleQueue
                // indices, which the rest of the type treats as one index space. Preparation
                // should fail instead of skipping a track.
                try trackGroups.append(TrackGroup(id: String(index), formats: [format]))
                let isAudio = format.sampleMimeType?.isAudio ?? false
                let isAudioVideo = isAudio || (format.sampleMimeType?.isVideo ?? false)
                isAudioOrVideo.append(isAudioVideo)
                state.haveAudioVideoTracks = state.haveAudioVideoTracks || isAudioVideo
                // TODO: icy metadata
            } catch {
                continue
            }
        }

        state.trackState = TrackState(
            tracks: .init(trackGroups: trackGroups),
            isAudioOrVideo: isAudioOrVideo
        )
        state.isPrepared = true

        effects.append(
            .sourceInfoRefreshed(duration: state.duration, seekMap: seekMap, isLive: false)
        )
        effects.append(.didPrepare)
    }

    func seekInsideBuffer(
        _ state: State,
        isAudioOrVideo: [Bool],
        position: CMTime,
        isSameAsLastSeekPosition: Bool
    ) -> Bool {
        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            if sampleQueue.getReadIndex() == 0, isSameAsLastSeekPosition { continue }

            let seekInsideQueue = sampleQueue.seek(time: position, allowTimeBeyondBuffer: false)
            if !seekInsideQueue, isAudioOrVideo[index] || !state.haveAudioVideoTracks {
                return false
            }
        }

        return true
    }

    func getExtractedSamplesCount(_ state: State) -> Int {
        state.sampleQueues.reduce(0) { $0 + $1.getWriteIndex() }
    }

    func getLargestQueuedTimestamp(_ state: State, includeDisabledTracks: Bool) -> CMTime {
        var largestQueuedTimestamp = CMTime.negativeInfinity

        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            if includeDisabledTracks || state.trackState.trackEnabledState[index] {
                largestQueuedTimestamp = max(
                    largestQueuedTimestamp,
                    sampleQueue.getLargestQueuedTimestamp()
                )
            }
        }

        return largestQueuedTimestamp
    }

    func isPendingReset(_ state: State) -> Bool {
        state.pendingResetPosition.isValid
    }

    func assertPrepared(_ state: State) {
        assert(state.isPrepared)
        assert(!state.trackState.tracks.isEmpty)
        assert(state.seekMap != nil)
    }

    func makeStreamHandlers() -> SampleStreamHolder.Handlers {
        .init(
            bufferedAheadDurationClosure: bufferedAheadDuration,
            isReadyClosure: isReady,
            errorClosure: maybeThrowError,
            readDataClosure: readData,
            skipDataClosure: skipData,
            installTrigger: installTrigger,
            removeTrigger: removeTrigger,
            testTrigger: testTrigger
        )
    }
}

// MARK: - Critical section + deferred effects

private extension ProgressiveMediaPeriod2 {
    enum Effect {
        case didPrepare
        case continueLoadingRequested
        case sourceInfoRefreshed(duration: CMTime, seekMap: SeekMap, isLive: Bool)
    }

    /// Runs `body` under the state lock, then flushes any queued upward callbacks *after* unlock.
    /// Reentrancy from a synchronous callback is therefore safe: the lock is already released.
    @inline(__always)
    func withState<R>(_ body: (inout State, inout [Effect]) throws -> R) rethrows -> R {
        var effects: [Effect] = []
        var callback: (any MediaPeriodCallback)?
        defer { deliver(effects, callback: callback) }

        return try stateLock.withLock { state -> R in
            defer { callback = state.callback }
            return try body(&state, &effects)
        }
    }

    func deliver(_ effects: [Effect], callback: (any MediaPeriodCallback)?) {
        guard !effects.isEmpty else { return }
        let listener = self.listener

        eventDispatch { [self] in
            for effect in effects {
                switch effect {
                case .didPrepare:
                    callback?.didPrepare(mediaPeriod: self)
                case .continueLoadingRequested:
                    callback?.continueLoadingRequested(with: self)
                case let .sourceInfoRefreshed(duration, seekMap, isLive):
                    listener?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: isLive)
                }
            }
        }
    }
}

// MARK: - Loader.Callback

extension ProgressiveMediaPeriod2: Loader.Callback {
    func onLoadStarted(
        loadable: ExtractingLoadable,
        onTime: Int64,
        loadDurationMs: Int64,
        retryCount: Int
    ) {}

    func onLoadCompleted(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64) {
        withState { state, effects in
            if !state.duration.isValid, let seekMap = state.seekMap {
                let largestQueuedTimestamp = getLargestQueuedTimestamp(state, includeDisabledTracks: false)
                state.duration = largestQueuedTimestamp == .negativeInfinity
                    ? .zero
                    : largestQueuedTimestamp + CMTime.from(microseconds: 10_000) // TODO: ask for real sample duration
                effects.append(
                    .sourceInfoRefreshed(
                        duration: state.duration,
                        seekMap: seekMap,
                        isLive: state.isLive
                    )
                )
            }

            state.loadingFinished = true
            effects.append(.continueLoadingRequested)
        }
    }

    func onLoadCancelled(
        loadable: ExtractingLoadable,
        onTime: Int64,
        loadDurationMs: Int64,
        released: Bool
    ) {
        withState { state, effects in
            guard !released else { return }
            do {
                try state.sampleQueues.forEach { try $0.reset() }
            } catch {
                fatalError()
            }
            if state.enabledTrackCount > 0 {
                effects.append(.continueLoadingRequested)
            }
        }
    }

    func onLoadError(
        loadable: ExtractingLoadable,
        onTime: Int64,
        loadDurationMs: Int64,
        error: Error,
        errorCount: Int
    ) -> Loader.LoadErrorAction {
        stateLock.withLock { state in
            do {
                let extractedSamplesCount = getExtractedSamplesCount(state)
                let madeProgress = extractedSamplesCount > state.extractedSamplesCountAtStartOfLoad
                let shouldRetry = try configureRetry(
                    &state,
                    loadable: loadable,
                    currentExtractedSampleCount: extractedSamplesCount
                )
                return shouldRetry
                    ? .createRetryAction(resetErrorCount: madeProgress, retryDelayMillis: 100)
                    : .dontRetry
            } catch {
                fatalError()
            }
        }
    }

    private func onLoaderReleased() {
        stateLock.withLock { state in
            do {
                try state.sampleQueues.forEach { try $0.release() }
                progressiveMediaExtractor.release()
            } catch {
                fatalError()
            }
        }
    }
}

// MARK: - ExtractorOutput

extension ProgressiveMediaPeriod2: ExtractorOutput {
    /// Called synchronously from the extractor actor. Previously this blocked on `queue.sync`.
    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        try stateLock.withLock { try prepareTrackOutput(&$0, id: id) }
    }

    func endTracks() {
        withState { state, effects in
            state.sampleQueuesBuild = true
            maybeFinishPrepare(&state, effects: &effects)
        }
    }

    func seekMap(seekMap: SeekMap) {
        withState { state, effects in
            setSeekMap(&state, seekMap: seekMap, effects: &effects)
        }
    }
}

// MARK: - SampleQueueDelegate

extension ProgressiveMediaPeriod2: SampleQueueDelegate {
    /// Invoked from the extractor thread. Requires `SampleQueue` to call its delegate outside its
    /// own lock — `maybeFinishPrepare` re-enters `getUpstreamFormat()`.
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format) {
        withState { state, effects in
            maybeFinishPrepare(&state, effects: &effects)
        }
    }
}

// MARK: - State

private extension ProgressiveMediaPeriod2 {
    struct State {
        var callback: (any MediaPeriodCallback)?
        var sampleQueues: [SampleQueue] = []
        var sampleQueueTrackIds: [Int] = []
        var sampleQueuesBuild: Bool = false

        var isPrepared: Bool = false
        var haveAudioVideoTracks: Bool = false
        var trackState: TrackState = .empty
        var seekMap: SeekMap?
        var duration: CMTime = .zero
        var isLive: Bool = false

        var seenFirstTrackSelection: Bool = false
        var notifyDiscontinuity: Bool = false
        var pendingInitialDiscontinuity: Bool = false
        var enabledTrackCount: Int = 0
        var isLengthKnown: Bool = true

        var lastSeekPosition: CMTime = .zero
        var pendingResetPosition: CMTime = .invalid
        var pendingDeferredRetry: Bool = false

        var extractedSamplesCountAtStartOfLoad: Int = 0
        var loadingFinished: Bool = false
        var didRelease: Bool = false
    }

    struct TrackState {
        let tracks: TrackGroupArray
        let isAudioOrVideo: [Bool]
        var trackEnabledState: [Bool]
        var trackNotifiedDownstreamFormats: [Bool]

        init(tracks: TrackGroupArray, isAudioOrVideo: [Bool]) {
            self.tracks = tracks
            self.isAudioOrVideo = isAudioOrVideo
            self.trackEnabledState = Array(repeating: false, count: tracks.count)
            self.trackNotifiedDownstreamFormats = Array(repeating: false, count: tracks.count)
        }

        static var empty: TrackState { .init(tracks: .empty, isAudioOrVideo: []) }
    }

    final class SampleStreamHolder: SampleStream {
        var bufferedAheadDuration: CMTime {
            handlers.bufferedAheadDurationClosure(track)
        }

        let track: Int
        private let handlers: Handlers

        struct Handlers {
            let bufferedAheadDurationClosure: (Int) -> CMTime
            let isReadyClosure: (Int) -> Bool
            let errorClosure: (Int) throws -> Void
            let readDataClosure: (Int, ReadFlags) throws -> SampleStreamReadResult
            let skipDataClosure: (Int, CMTime) throws -> Int
            let installTrigger: (Int, TriggerCondition, ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken
            let removeTrigger: (Int, QueueTriggerToken) -> Void
            let testTrigger: (Int, QueueTriggerToken) -> Bool
        }

        init(track: Int, handlers: Handlers) {
            self.track = track
            self.handlers = handlers
        }

        func isReady() -> Bool { handlers.isReadyClosure(track) }
        func maybeThrowError() throws { try handlers.errorClosure(track) }

        func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
            try handlers.readDataClosure(track, readFlags)
        }

        func skipData(position: CMTime) throws -> Int {
            try handlers.skipDataClosure(track, position)
        }

        func installTrigger(
            condition: TriggerCondition,
            _ body: ((QueueTriggerToken) -> Void)?
        ) -> QueueTriggerToken {
            handlers.installTrigger(track, condition, body)
        }

        func removeTrigger(_ token: QueueTriggerToken) { handlers.removeTrigger(track, token) }
        func testTrigger(_ token: QueueTriggerToken) -> Bool { handlers.testTrigger(track, token) }
    }
}

// MARK: - ExtractingLoadable

extension ProgressiveMediaPeriod2 {
    final class ExtractingLoadable: Loadable {
        private let url: URL
        private let syncActor: PlayerActor
        private let dataSourceFactory: DataSourceFactory
        private let progressiveMediaExtractor: ProgressiveMediaExtractor
        private let extractorOutput: ExtractorOutput
        private let loadCondition: AsyncConditionVariable
        private let continueLoadingCheckIntervalBytes: Int
        private let requestContiniueLoading: () -> Void
        private var position: Int = 0

        private var pendingExtractorSeek = true
        private var seekTime: CMTime = .zero
        private var didFinish: Bool = false

        init(
            url: URL,
            syncActor: PlayerActor,
            dataSourceFactory: DataSourceFactory,
            progressiveMediaExtractor: ProgressiveMediaExtractor,
            extractorOutput: ExtractorOutput,
            loadCondition: AsyncConditionVariable,
            continueLoadingCheckIntervalBytes: Int,
            requestContiniueLoading: @escaping () -> Void
        ) {
            self.url = url
            self.syncActor = syncActor
            self.dataSourceFactory = dataSourceFactory
            self.progressiveMediaExtractor = progressiveMediaExtractor
            self.extractorOutput = extractorOutput
            self.loadCondition = loadCondition
            self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
            self.requestContiniueLoading = requestContiniueLoading
        }

        func load(_ isolation: isolated any Actor) async throws {
            syncActor.assertIsolated()
            var result: ExtractorReadResult = .continueRead
            var openedDataSource: any DataSource?

            while result == .continueRead, !Task.isCancelled {
                do {
                    let dataSpec = buildDataSpec(position: position)
                    let dataSource = try await dataSourceFactory.createDataSource(dataSpec: dataSpec, isolation)
                    openedDataSource = dataSource

                    let length = dataSource.getContentLenght(dataSpec: dataSpec, isolation)
                    guard !Task.isCancelled else { throw CancellationError() }

                    try await progressiveMediaExtractor.prepare(
                        dataReader: dataSource,
                        url: url,
                        response: dataSource.getURLResponse(isolation),
                        position: position,
                        lenght: length,
                        output: extractorOutput,
                        isolation
                    )

                    if pendingExtractorSeek {
                        try progressiveMediaExtractor.seek(
                            position: position,
                            time: seekTime,
                            isolation
                        )
                        pendingExtractorSeek = false
                    }

                    while result == .continueRead, !Task.isCancelled {
                        try await loadCondition.wait()
                        guard !Task.isCancelled else { throw CancellationError() }
                        result = try await progressiveMediaExtractor.read(isolation)

//                        if let currentInputPosition = progressiveMediaExtractor.getCurrentInputPosition(isolation: isolation),
//                           currentInputPosition > position + continueLoadingCheckIntervalBytes {
//                            position = currentInputPosition
//                            loadCondition.close()
//                            requestContiniueLoading()
//                        }
                    }
                } catch {
                    await postLoadTask(
                        result: &result,
                        dataSource: openedDataSource,
                        isolation
                    )
                    throw error
                }

                await postLoadTask(
                    result: &result,
                    dataSource: openedDataSource,
                    isolation
                )
            }
        }

        func setLoadPosition(position: Int, time: CMTime) {
            self.position = position
            self.seekTime = time
            pendingExtractorSeek = true
        }

        private func postLoadTask(
            result: inout ExtractorReadResult,
            dataSource: (any DataSource)?,
            _ isolation: isolated any Actor
        ) async {
            if case let .seek(offset) = result {
                position = offset
                result = .continueRead
            } else if let currentInputPosition = progressiveMediaExtractor.getCurrentInputPosition(isolation) {
                position = currentInputPosition
            }

            try? await dataSource?.close(isolation)
        }

        private func buildDataSpec(position: Int) -> DataSpec {
            DataSpec.Builder(url: url)
                .setPosition(position)
                // TODO: .setKey(customCacheKey)
                .setFlags([.dontCacheIfLengthUnknown, .allowCacheFragmentation])
                // TODO: .setAllHTTPHeaderFields(requestHeaders)
                .build()
        }
    }
}
