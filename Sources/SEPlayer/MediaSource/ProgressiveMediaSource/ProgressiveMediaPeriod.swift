//
//  ProgressiveMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.08.2026.
//

// swiftlint:disable file_length

import CoreMedia
import DataSource
import Decoder
import Extractor
import Foundation
import os
import SEPlayerCommon

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
final class ProgressiveMediaPeriod: MediaPeriod {
    protocol Listener: AnyObject {
        func sourceInfoRefreshed(duration: CMTime, seekMap: SeekMap, isLive: Bool)
    }

    /// Delivery policy for upward callbacks. Defaults to the queue passed at init so existing
    /// call sites keep playback-thread delivery. Pass `{ $0() }` for inline delivery on the
    /// calling thread if the callback owner is itself thread-safe.
    typealias EventDispatch = (@escaping () -> Void) -> Void

    var trackGroups: TrackGroupArray { stateLock.withLock { $0.trackState.tracks } }

    /// Advisory: the conjunction is not atomic. Neither was the original.
    var isLoading: Bool { loader.isLoading() && (loadCondition.isOpen || readAhead.isEnabled) }

    private let url: URL
    private let queue: Queue
    private let loaderSyncActor: PlayerActor
    private let dataSourceFactory: DataSourceFactory
    private let transferListener: TransferListener?
    private weak var listener: Listener?
    private let allocator: Allocator
    private let continueLoadingCheckIntervalBytes: Int
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy
    private let loader: Loader
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let loadCondition: AsyncConditionVariable
    private let eventDispatch: EventDispatch
    /// Lets the data sources load ahead of the extractor while the player loads, and tells how much they hold.
    private let readAhead = ReadAhead(limit: 1024 * 1024 * 1024) // 1 GB

    private let stateLock = UnfairMutex(State())

    init(
        url: URL,
        queue: Queue,
        loadQueue: Queue,
        dataSourceFactory: DataSourceFactory,
        transferListener: TransferListener? = nil,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        listener: Listener,
        allocator: Allocator,
        continueLoadingCheckIntervalBytes: Int,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy = DefaultLoadErrorHandlingPolicy(),
        eventDispatch: EventDispatch? = nil
    ) {
        self.url = url
        self.queue = queue
        self.loaderSyncActor = loadQueue.playerActor()
        self.dataSourceFactory = dataSourceFactory
        self.transferListener = transferListener
        self.loader = Loader(workQueue: queue, loadQueue: loadQueue)
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.loadCondition = AsyncConditionVariable()
        self.listener = listener
        self.allocator = allocator
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
        self.eventDispatch = eventDispatch ?? { work in queue.async { work() } }
        readAhead.onAvailableBytesChange = { [weak self] in self?.readAheadDidChange() }
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

        queues.forEach { try? $0.preRelease() }

        loader.release { [weak self] in
            self?.onLoaderReleased()
        }
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        SELogger.info(.progressive, "Preparing \(url.lastPathComponent) at \(time.seconds)")
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

            for index in 0 ..< selections.count {
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
                for index in 0 ..< streams.count where streams[index] != nil {
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
        let (continuedLoading, loadsAhead) = stateLock.withLock { state -> (Bool, Bool) in
            state.playbackSpeed = loadingInfo.playbackSpeed
            // A load that failed with a fatal error doesn't start over: its error stays for the player to throw.
            if state.didRelease
                || state.loadingFinished
                || loader.hasFatalError()
                || state.pendingDeferredRetry
                || (state.isPrepared && state.enabledTrackCount == 0) {
                return (false, false)
            }

            var continuedLoading: Bool
            if buffersBytes(state) {
                // Loading goes on in the data sources; the extractor follows playback.
                continuedLoading = true
                if !isExtractionWindowFull(state) {
                    _ = loadCondition.open()
                }
            } else {
                continuedLoading = loadCondition.open()
            }
            if !loader.isLoading() {
                startLoading(&state)
                continuedLoading = true
            }
            if buffersBytes(state) != state.loggedBuffersBytes {
                state.loggedBuffersBytes = buffersBytes(state)
                SELogger.debug(.progressive, state.loggedBuffersBytes
                    ? "Loaded bytes count as buffered: the extractor follows playback"
                    : "Only extracted samples count as buffered")
            }
            return (continuedLoading, buffersBytes(state))
        }
        // Outside the lock: the data sources report back to this period at once. Loading ahead of the extractor
        // only helps where the loaded bytes count as buffered; elsewhere the extractor keeps up with the loading.
        readAhead.isEnabled = continuedLoading && loadsAhead
        return continuedLoading
    }

    func stopLoading() {
        stateLock.withLock { state in
            if !loader.isLoading()
                || !state.isPrepared
                || (state.isPrepared && state.enabledTrackCount == 0)
                || buffersBytes(state) {
                return
            }
            loadCondition.close()
        }
        readAhead.isEnabled = false
    }

    func reevaluateBuffer(position: CMTime) {
        stateLock.withLock { maybeResumeExtraction(&$0) }
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

            return queuedPosition(state) + unextractedDuration(state)
        }
    }

    func seek(position: CMTime) throws -> CMTime {
        try stateLock.withLock { state in
            try seek(&state, position: position)
        }
    }

    func seekForRecovery(position: CMTime) throws -> CMTime {
        try withState { state, _ in
            guard state.seekMap?.isSeekable() == true || position == .zero else {
                // Buffered recovery is possible even when the extractor cannot seek.
                guard !suppressRead(state),
                      state.sampleQueues.enumerated().allSatisfy({ index, sampleQueue in
                          !state.trackState.trackEnabledState[index] || sampleQueue.canSeekWithinBuffer(to: position)
                      }) else { throw RendererRecoveryError.positionUnavailable }
                for (index, sampleQueue) in state.sampleQueues.enumerated() where state.trackState.trackEnabledState[index] {
                    guard case .success = sampleQueue.seekWithinBuffer(to: position) else {
                        throw RendererRecoveryError.positionUnavailable
                    }
                }
                state.notifyDiscontinuity = false
                state.lastSeekPosition = position
                return position
            }
            return try seek(&state, position: position)
        }
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        stateLock.withLock { state in
            assertPrepared(state)
            guard let seekMap = state.seekMap, seekMap.isSeekable() else {
                return .zero
            }

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
        let dataType = stateLock.withLock { Self.dataType($0) }
        try loader.maybeThrowError(minRetryCount: loadErrorHandlingPolicy.getMinimumLoadableRetryCount(dataType: dataType))
    }

    /// A stream of unknown length and duration is live: what it misses while it retries is gone.
    private static func dataType(_ state: State) -> DataType {
        let isLive = !state.isLengthKnown && state.seekMap?.getDuration().isValid != true
        return isLive ? .mediaProgressiveLive : .media
    }

    func readData(track: Int, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        try withState { state, effects in
            guard !suppressRead(state) else { return .nothingRead }
            maybeNotifyDownstreamFormat(&state, track: track)

            let result = try state.sampleQueues[track].read(
                readFlags: readFlags,
                loadingFinished: state.loadingFinished
            )
            maybeResumeExtraction(&state)

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
            maybeResumeExtraction(&state)
            if skipCount == 0 {
                try maybeStartDeferredRetry(&state, track: track, effects: &effects)
            }

            return skipCount
        }
    }

    func seekWithinBuffer(track: Int, position: CMTime) -> SampleStreamSeekResult {
        stateLock.withLock { state in
            guard !suppressRead(state), state.isPrepared,
                  state.sampleQueues.indices.contains(track) else {
                return .unavailable
            }
            let sampleQueue = state.sampleQueues[track]
            return sampleQueue.seekWithinBuffer(to: position)
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

private extension ProgressiveMediaPeriod {
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
            SELogger.debug(.progressive, "Seek to \(position.seconds) inside the buffer")
            return position
        }

        SELogger.debug(.progressive, "Seek to \(position.seconds) outside the buffer\(loader.isLoading() ? ", canceling the load" : "")")

        state.pendingDeferredRetry = false
        state.pendingResetPosition = position
        state.loadingFinished = false
        state.sampleQueues.forEach { $0.setLoadingFinished(false) }
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
            transferListener: transferListener,
            progressiveMediaExtractor: progressiveMediaExtractor,
            extractorOutput: self,
            loadCondition: loadCondition,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes,
            readAhead: readAhead,
            requestContiniueLoading: { [weak self] in
                self?.withState { _, effects in effects.append(.continueLoadingRequested) }
            },
            extractionDidAdvance: { [weak self] in
                self?.extractionDidAdvance() ?? false
            }
        )

        if state.isPrepared {
            guard let seekMap = state.seekMap else { return }

            if state.duration.isValid, state.pendingResetPosition > state.duration {
                state.loadingFinished = true
                state.sampleQueues.forEach { $0.setLoadingFinished(true) }
                state.pendingResetPosition = .invalid
                return
            }

            let pendingResetPosition = state.pendingResetPosition
            let seekPoints = seekMap.getSeekPoints(for: pendingResetPosition)
            SELogger.info(.progressive, "Loading from byte \(seekPoints.first.position), the sync point at \(seekPoints.first.time.seconds) for \(pendingResetPosition.seconds)")
            loadable.setLoadPosition(position: seekPoints.first.position, time: pendingResetPosition)
            state.sampleQueues.forEach { $0.setStartTime(pendingResetPosition) }
            state.pendingResetPosition = .invalid
        }

        if !state.isPrepared {
            SELogger.info(.progressive, "Loading \(url.lastPathComponent) from the start")
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

    func maybeNotifyDownstreamFormat(_ state: inout State, track: Int) {}

    func suppressRead(_ state: State) -> Bool {
        state.notifyDiscontinuity || isPendingReset(state)
    }

    func prepareTrackOutput(_ state: inout State, id: Int) throws -> TrackOutput {
        for index in 0 ..< state.sampleQueues.count where id == state.sampleQueueTrackIds[index] {
            return state.sampleQueues[index]
        }

        let trackOutput = try SampleQueue(queue: queue, allocator: allocator)
        trackOutput.delegate = self
        // Samples go once the renderer has read this far past them. The player discards behind playback only when it
        // updates, which can be rare while playback runs.
        trackOutput.backBufferDuration = SampleQueue.readBackBufferDuration
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
              let seekMap = state.seekMap else {
            return
        }

        for sampleQueue in state.sampleQueues where sampleQueue.getUpstreamFormat() == nil {
            return
        }

        loadCondition.close()
        var trackGroups: [TrackGroup] = []
        var isAudioOrVideo: [Bool] = []

        for index in 0 ..< state.sampleQueues.count {
            guard let format = state.sampleQueues[index].getUpstreamFormat() else {
                continue
            }

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
        SELogger.info(.progressive, "Prepared \(url.lastPathComponent): \(trackGroups.count) tracks, duration \(state.duration.seconds), \(seekMap.isSeekable() ? "seekable" : "not seekable")")
        for group in trackGroups {
            SELogger.debug(.progressive, "Track \(group.id): \(group.getFormat(index: 0))")
        }

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

    // MARK: Extraction window

    /// Whether what lies ahead of the extracted samples is buffered as loaded bytes, so the extractor runs only a
    /// little ahead of playback. That needs the average bitrate, from the length and the duration of the media.
    func buffersBytes(_ state: State) -> Bool {
        state.isPrepared
            && !state.loadingFinished
            && !isPendingReset(state)
            && state.duration.isNumeric && state.duration > .zero
            && (readAhead.resourceLength ?? 0) > 0
    }

    /// How far the extracted samples go, over the enabled audio and video tracks.
    func queuedPosition(_ state: State) -> CMTime {
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

    /// The media held in loaded bytes that are not extracted yet, at the average bitrate of the resource. When the
    /// bytes go on to the end of the resource, it is all of the media after the extracted samples: the average leaves
    /// out the bytes of the container, such as its header.
    func unextractedDuration(_ state: State) -> CMTime {
        guard buffersBytes(state), let length = readAhead.resourceLength else {
            return .zero
        }
        if readAhead.holdsToEnd {
            return max(.zero, state.duration - queuedPosition(state))
        }
        let seconds = Double(readAhead.availableBytes) / Double(length) * state.duration.seconds
        return CMTime(seconds: seconds, preferredTimescale: 1000)
    }

    /// The least and the most queued ahead of the reads, over the enabled audio and video tracks, or all enabled
    /// tracks without those.
    func queuedAhead(_ state: State) -> (least: CMTime, most: CMTime)? {
        let enabled = state.sampleQueues.indices.filter { state.trackState.trackEnabledState[$0] }
        let audioVideo = enabled.filter { state.trackState.isAudioOrVideo[$0] }
        let durations = (audioVideo.isEmpty ? enabled : audioVideo).map { state.sampleQueues[$0].queuedAheadDuration }
        guard let least = durations.min(), let most = durations.max() else {
            return nil
        }
        return (least, most)
    }

    func extractionWindow(_ state: State) -> (low: CMTime, high: CMTime) {
        let speed = Float64(max(1, state.playbackSpeed))
        return (
            CMTimeMultiplyByFloat64(Self.extractionLowWater, multiplier: speed),
            CMTimeMultiplyByFloat64(Self.extractionHighWater, multiplier: speed)
        )
    }

    /// Whether the extractor is far enough ahead of playback to pause. A track that runs far ahead of the others, as
    /// in media whose tracks are badly interleaved, pauses it too, unless another track runs short: the extractor may
    /// have to read on through the one ahead to reach it, and the paused extractor would wait for playback that waits
    /// for that track.
    func isExtractionWindowFull(_ state: State) -> Bool {
        guard buffersBytes(state), let queued = queuedAhead(state) else {
            return false
        }
        let window = extractionWindow(state)
        return queued.least >= window.high
            || (queued.most >= CMTimeMultiply(window.high, multiplier: 6) && queued.least >= window.low)
    }

    /// Lets the extractor go on once playback has caught up with it.
    func maybeResumeExtraction(_ state: inout State) {
        guard buffersBytes(state), !loadCondition.isOpen else { return }
        let isLow = queuedAhead(state).map { $0.least < extractionWindow(state).low } ?? true
        if isLow {
            SELogger.verbose(.progressive, "Extraction resumes: \(queuedAhead(state).map { "\($0.least.seconds)s" } ?? "nothing") queued ahead")
            _ = loadCondition.open()
        }
    }

    static let extractionLowWater = CMTime(value: 3, timescale: 1)
    static let extractionHighWater = CMTime(value: 5, timescale: 1)
    /// Changes of the unextracted media smaller than this don't ask the player to look again.
    static let unextractedNotificationStep = CMTime(value: 1, timescale: 1)

    /// A prepared period may have no tracks: media whose streams no extractor reads, such as MPEG-2 video in TS.
    func assertPrepared(_ state: State) {
        assert(state.isPrepared)
        assert(state.seekMap != nil)
    }

    func makeStreamHandlers() -> SampleStreamHolder.Handlers {
        .init(
            bufferedAheadDurationClosure: bufferedAheadDuration,
            isReadyClosure: isReady,
            errorClosure: maybeThrowError,
            readDataClosure: readData,
            skipDataClosure: skipData,
            seekWithinBufferClosure: seekWithinBuffer,
            installTrigger: installTrigger,
            removeTrigger: removeTrigger,
            testTrigger: testTrigger
        )
    }
}

// MARK: - Read-ahead

private extension ProgressiveMediaPeriod {
    /// The data sources hold another amount of loaded bytes: the buffered media follows.
    func readAheadDidChange() {
        let changedQueues = withState { state, effects -> [SampleQueue] in
            guard !state.didRelease else { return [] }
            let duration = unextractedDuration(state)
            let changed = state.sampleQueues.filter { $0.setUnextractedDuration(duration) }

            // The buffered position the player shows follows too.
            if CMTimeAbsoluteValue(duration - state.notifiedUnextractedDuration) >= Self.unextractedNotificationStep {
                state.notifiedUnextractedDuration = duration
                effects.append(.continueLoadingRequested)
            }
            return changed
        }
        // Outside the lock: the triggers wake the player.
        changedQueues.forEach { $0.evaluateTriggers() }
    }

    /// Pauses the extractor once it is far enough ahead of playback.
    ///
    /// - Returns: Whether the extraction window decides when the extractor runs. Otherwise the player does.
    func extractionDidAdvance() -> Bool {
        stateLock.withLock { state in
            guard buffersBytes(state) else { return false }
            if isExtractionWindowFull(state), loadCondition.isOpen {
                SELogger.verbose(.progressive, "Extraction pauses: \(queuedAhead(state).map { "\($0.least.seconds)–\($0.most.seconds)s" } ?? "nothing") queued ahead")
                loadCondition.close()
            }
            return true
        }
    }
}

// MARK: - Critical section + deferred effects

private extension ProgressiveMediaPeriod {
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

extension ProgressiveMediaPeriod: Loader.Callback {
    func onLoadStarted(
        loadable: ExtractingLoadable,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        retryCount: Int
    ) {}

    func onLoadCompleted(loadable: ExtractingLoadable, onTime: DispatchTime, loadDuration: DispatchTimeInterval) {
        SELogger.info(.progressive, "Loaded \(url.lastPathComponent) to the end in \(loadDuration.totalMilliseconds)ms")
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
            state.sampleQueues.forEach { $0.setLoadingFinished(true) }
            effects.append(.continueLoadingRequested)
        }
    }

    func onLoadCancelled(
        loadable: ExtractingLoadable,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        released: Bool
    ) {
        SELogger.debug(.progressive, "Load of \(url.lastPathComponent) canceled after \(loadDuration.totalMilliseconds)ms\(released ? ", released" : "")")
        withState { state, effects in
            guard !released else { return }
            state.sampleQueues.forEach { try? $0.reset() }
            if state.enabledTrackCount > 0 {
                effects.append(.continueLoadingRequested)
            }
        }
    }

    func onLoadError(
        loadable: ExtractingLoadable,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        error: Error,
        errorCount: Int
    ) -> Loader.LoadErrorAction {
        withState { state, effects in
            let errorInfo = LoadErrorInfo(dataType: Self.dataType(state), error: error, errorCount: errorCount)
            guard let retryDelay = loadErrorHandlingPolicy.getRetryDelay(for: errorInfo) else {
                SELogger.error(.progressive, "Progressive load failed with a fatal error, not retrying: \(error)")
                // Nothing loads any more: the player looks for the error without waiting for the buffer to run out.
                effects.append(.continueLoadingRequested)
                return .dontRetryFatal
            }
            SELogger.warning(.progressive, "Progressive load failed (attempt \(errorCount)), retrying in \(retryDelay.totalMilliseconds)ms: \(error)")
            do {
                let extractedSamplesCount = getExtractedSamplesCount(state)
                // A load that got somewhere before it failed starts counting its errors over.
                let madeProgress = extractedSamplesCount > state.extractedSamplesCountAtStartOfLoad
                let shouldRetry = try configureRetry(
                    &state,
                    loadable: loadable,
                    currentExtractedSampleCount: extractedSamplesCount
                )
                return shouldRetry
                    ? .createRetryAction(resetErrorCount: madeProgress, retryDelay: retryDelay)
                    : .dontRetry
            } catch {
                effects.append(.continueLoadingRequested)
                return .dontRetryFatal
            }
        }
    }

    private func onLoaderReleased() {
        stateLock.withLock { state in
            state.sampleQueues.forEach { try? $0.release() }
            progressiveMediaExtractor.release()
        }
    }
}

// MARK: - ExtractorOutput

extension ProgressiveMediaPeriod: ExtractorOutput {
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

extension ProgressiveMediaPeriod: SampleQueueDelegate {
    /// Invoked from the extractor thread. Requires `SampleQueue` to call its delegate outside its
    /// own lock — `maybeFinishPrepare` re-enters `getUpstreamFormat()`.
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format) {
        withState { state, effects in
            maybeFinishPrepare(&state, effects: &effects)
        }
    }
}

// MARK: - State

private extension ProgressiveMediaPeriod {
    struct State {
        var callback: (any MediaPeriodCallback)?
        /// Whether loaded bytes counted as buffered when last logged.
        var loggedBuffersBytes = false
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

        var playbackSpeed: Float = 1
        /// The unextracted media the player last heard about.
        var notifiedUnextractedDuration: CMTime = .zero
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
        private var requiresFormat = false

        struct Handlers {
            let bufferedAheadDurationClosure: (Int) -> CMTime
            let isReadyClosure: (Int) -> Bool
            let errorClosure: (Int) throws -> Void
            let readDataClosure: (Int, ReadFlags) throws -> SampleStreamReadResult
            let skipDataClosure: (Int, CMTime) throws -> Int
            let seekWithinBufferClosure: (Int, CMTime) -> SampleStreamSeekResult
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
            let result = try handlers.readDataClosure(track, requiresFormat ? readFlags.union(.requireFormat) : readFlags)
            if case .didReadFormat = result { requiresFormat = false }
            return result
        }

        func skipData(position: CMTime) throws -> Int {
            try handlers.skipDataClosure(track, position)
        }

        func seekWithinBuffer(to position: CMTime) throws -> SampleStreamSeekResult {
            let result = handlers.seekWithinBufferClosure(track, position)
            if case .success = result { requiresFormat = true }
            return result
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

extension ProgressiveMediaPeriod {
    final class ExtractingLoadable: Loadable {
        private let url: URL
        private let syncActor: PlayerActor
        private let dataSourceFactory: DataSourceFactory
        private let transferListener: TransferListener?
        private let progressiveMediaExtractor: ProgressiveMediaExtractor
        private let extractorOutput: ExtractorOutput
        private let loadCondition: AsyncConditionVariable
        private let continueLoadingCheckIntervalBytes: Int
        private let readAhead: ReadAhead
        private let requestContiniueLoading: () -> Void
        /// Lets the period pause the extractor; `true` if the period, not the player, decides when it runs.
        private let extractionDidAdvance: () -> Bool
        private var position: Int = 0

        private var pendingExtractorSeek = true
        private var seekTime: CMTime = .zero
        private var didFinish: Bool = false

        init(
            url: URL,
            syncActor: PlayerActor,
            dataSourceFactory: DataSourceFactory,
            transferListener: TransferListener?,
            progressiveMediaExtractor: ProgressiveMediaExtractor,
            extractorOutput: ExtractorOutput,
            loadCondition: AsyncConditionVariable,
            continueLoadingCheckIntervalBytes: Int,
            readAhead: ReadAhead,
            requestContiniueLoading: @escaping () -> Void,
            extractionDidAdvance: @escaping () -> Bool
        ) {
            self.url = url
            self.syncActor = syncActor
            self.dataSourceFactory = dataSourceFactory
            self.transferListener = transferListener
            self.progressiveMediaExtractor = progressiveMediaExtractor
            self.extractorOutput = extractorOutput
            self.loadCondition = loadCondition
            self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
            self.readAhead = readAhead
            self.requestContiniueLoading = requestContiniueLoading
            self.extractionDidAdvance = extractionDidAdvance
        }

        func load(_ isolation: isolated any Actor) async throws {
            syncActor.assertIsolated()
            var result: ExtractorReadResult = .continueRead
            var openedDataSource: any DataSource?

            while result == .continueRead, !Task.isCancelled {
                do {
                    let dataSpec = buildDataSpec(position: position)
                    let dataSource = dataSourceFactory.createDataSource(transferListener: transferListener)
                    dataSource.setReadAhead(readAhead)
                    openedDataSource = dataSource

                    // Extractors take the length as the absolute end of the stream, and this load may
                    // start in the middle of it.
                    let length = try await dataSource.open(dataSpec: dataSpec, isolation).map { $0 + position }
                    guard !Task.isCancelled else { throw CancellationError() }

                    try await progressiveMediaExtractor.prepare(
                        dataReader: dataSource,
                        url: url,
                        response: dataSource.getURLResponse(isolation),
                        position: position,
                        length: length,
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

                    var checkedPosition = position
                    while result == .continueRead, !Task.isCancelled {
                        try await loadCondition.wait()
                        guard !Task.isCancelled else {
                            throw CancellationError()
                        }
                        result = try await progressiveMediaExtractor.read(isolation)
                        if extractionDidAdvance() { continue }

                        // Pause every few bytes and let the player decide whether to go on. Without
                        // this, cached media loads to the end before the player can stop it.
                        if let inputPosition = progressiveMediaExtractor.getCurrentInputPosition(isolation),
                           inputPosition > checkedPosition + continueLoadingCheckIntervalBytes {
                            checkedPosition = inputPosition
                            loadCondition.close()
                            requestContiniueLoading()
                        }
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
            Self.dataSpec(url: url, position: position)
        }

        static func dataSpec(url: URL, position: Int) -> DataSpec {
            DataSpec.Builder(url: url)
                .setPosition(position)
                // TODO: .setKey(customCacheKey)
                // A file doesn't change: played again, it comes from storage where the player keeps it.
                .setFlags([.dontCacheIfLengthUnknown, .allowCacheFragmentation, .keepLoadedBytes, .storeOnDisk])
                // TODO: .setAllHTTPHeaderFields(requestHeaders)
                .build()
        }
    }
}
