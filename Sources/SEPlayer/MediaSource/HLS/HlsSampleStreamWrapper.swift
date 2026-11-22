//
//  HlsSampleStreamWrapper.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.hls.HlsSampleStreamWrapper
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

// swiftlint:disable file_length

import CoreMedia
import DataSource
import Extractor
import Foundation
import SEPlayerCommon

/// Loads ``HlsMediaChunk``s from an ``HlsChunkSource`` and provides the samples of their tracks as
/// ``SampleStream``s.
///
/// A wrapper loads one group of renditions: the variants, or one audio rendition group. It prepares either from the
/// multivariant playlist alone, when it declares the codecs, or by loading the first chunk and building its tracks
/// from the samples.
///
/// Thread safety: like ``ProgressiveMediaPeriod``, all mutable state is behind `stateLock`, the outermost lock;
/// `SampleQueue` and `Loader` are leaf locks. The player queue drives preparation, track selection, seeks and
/// loading; extractors write from the loader queue; renderers read through the sample streams. Calls up to the
/// callback are made after unlock, on the player queue.
final class HlsSampleStreamWrapper {
    /// A callback to be notified of ``HlsSampleStreamWrapper`` events.
    protocol Callback: AnyObject {
        /// Called when the wrapper has been prepared.
        func onPrepared(_ wrapper: HlsSampleStreamWrapper)
        /// Called when the wrapper needs a media playlist that isn't loaded yet.
        func onPlaylistRefreshRequired(url: URL)
        /// Called when the wrapper would continue loading if asked.
        func continueLoadingRequested(_ wrapper: HlsSampleStreamWrapper)
    }

    /// How a sample stream finds its sample queue.
    enum SampleQueueBinding {
        /// The sample queues aren't mapped to track groups yet.
        case pending
        /// The track group has no sample queue.
        case noMapping
        /// The sample queue of the track group.
        case bound(Int)
    }

    /// Identifies the wrapper's track groups.
    let uid: String
    /// The type of the tracks: `.unknown` for the variants, which carry several types.
    let trackType: TrackType

    var trackGroups: TrackGroupArray { stateLock.withLock { $0.trackGroups } }
    var primaryTrackGroupIndex: Int { stateLock.withLock { $0.primaryTrackGroupIndex } }
    var isLoading: Bool { loader.isLoading() }
    /// Whether scrubbing loads keyframes of I-frame playlists rather than whole segments.
    var scrubsWithIFrames: Bool { chunkSource.scrubsWithIFrames }

    private let queue: Queue
    private let chunkSource: HlsChunkSource
    private let muxedAudioFormat: AnyFormat?
    private let loadErrorHandlingPolicy: LoadErrorHandlingPolicy
    /// Hears how many bytes the sample queues hold.
    private let bufferedBytesCounter: BufferedBytesCounter?
    private let loader: Loader
    private weak var callback: Callback?
    private let stateLock = UnfairMutex(State())

    init(
        uid: String,
        trackType: TrackType,
        callback: Callback,
        chunkSource: HlsChunkSource,
        positionUs: CMTime,
        muxedAudioFormat: AnyFormat?,
        queue: Queue,
        loaderQueue: Queue,
        loadErrorHandlingPolicy: LoadErrorHandlingPolicy,
        bufferedBytesCounter: BufferedBytesCounter? = nil
    ) {
        self.bufferedBytesCounter = bufferedBytesCounter
        self.uid = uid
        self.trackType = trackType
        self.callback = callback
        self.chunkSource = chunkSource
        self.muxedAudioFormat = muxedAudioFormat
        self.loadErrorHandlingPolicy = loadErrorHandlingPolicy
        self.queue = queue
        loader = Loader(workQueue: queue, loadQueue: loaderQueue)
        stateLock.withLock {
            $0.lastSeekPosition = positionUs
            $0.pendingResetPosition = positionUs
        }
    }

    // MARK: - Preparation

    /// Loads the first chunk to build the tracks from its samples.
    func continuePreparing() {
        let (isPrepared, position) = stateLock.withLock { ($0.isPrepared, $0.lastSeekPosition) }
        guard !isPrepared else { return }
        let loadingInfo = LoadingInfo(playbackPosition: position, playbackSpeed: 1, lastRebufferRealtime: .invalid)
        continueLoading(with: loadingInfo)
    }

    /// Prepares the wrapper from the multivariant playlist alone. Its sample queues are mapped to the track groups
    /// once the first chunk declares its tracks.
    func prepareWithMultivariantPlaylistInfo(trackGroups: [TrackGroup], primaryTrackGroupIndex: Int) {
        withState { state, effects in
            state.trackGroups = TrackGroupArray(trackGroups: trackGroups)
            state.primaryTrackGroupIndex = primaryTrackGroupIndex
            state.isPrepared = true
            effects.append(.prepared)
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

    func maybeThrowError() throws {
        try loader.maybeThrowError(
            minRetryCount: loadErrorHandlingPolicy.getMinimumLoadableRetryCount(dataType: .media)
        )
        try chunkSource.maybeThrowError()
    }

    /// Called when a media playlist failed to load: excludes its track if the selection has another.
    ///
    /// - Parameter forceRetry: Whether the playlist must load again rather than fall back to another track.
    /// - Returns: Whether the track of the playlist was excluded, or the wrapper doesn't play it.
    func onPlaylistError(url: URL, errorInfo: LoadErrorInfo, forceRetry: Bool) -> Bool {
        guard chunkSource.obtainsChunks(forPlaylist: url) else { return true }
        var exclusionDuration = CMTime.invalid
        if !forceRetry,
           let fallback = loadErrorHandlingPolicy.getFallbackSelection(
               for: chunkSource.fallbackOptions(),
               loadErrorInfo: errorInfo
           ),
           fallback.type == .track {
            exclusionDuration = fallback.exclusionDuration
        }
        // Called in any case: the chunk source notes that the playlist it waits for failed.
        return chunkSource.onPlaylistError(url: url, exclusionDuration: exclusionDuration) && exclusionDuration.isValid
    }

    /// Whether the wrapper sets the timeline of each discontinuity for the others.
    func setIsTimestampMaster(_ isTimestampMaster: Bool) {
        chunkSource.isTimestampMaster = isTimestampMaster
    }

    /// Called when a playlist the wrapper may need changed: a pending chunk can now load, and the part a preload
    /// hint announced may be confirmed or replaced.
    func onPlaylistUpdated() {
        let (released, isPrepared, lastChunk) = stateLock.withLock {
            ($0.released, $0.isPrepared, $0.mediaChunks.last)
        }
        guard !released else { return }
        if let lastChunk, !lastChunk.isPublished {
            switch chunkSource.publicationState(of: lastChunk) {
            case .published:
                lastChunk.publish()
            case .preload:
                // The playlist that confirms it is to come.
                callback?.onPlaylistRefreshRequired(url: lastChunk.playlistUrl)
            case .removed:
                SELogger.debug(.hls, "HLS \(uid) preload hint \(lastChunk.dataSpec.url.lastPathComponent) was replaced")
                if loader.isLoading() {
                    loader.cancelLoading()
                    return
                }
                stateLock.withLock { discardUpstream(&$0, preferredQueueSize: $0.mediaChunks.count - 1) }
            }
        }
        // Preparation drives itself: the period doesn't ask an unprepared wrapper to load.
        if isPrepared {
            callback?.continueLoadingRequested(self)
        } else {
            continuePreparing()
        }
    }

    func release() {
        let queues: [SampleQueue] = stateLock.withLock { state in
            guard !state.released else { return [] }
            state.released = true
            state.streams.removeAll()
            // The chunks keep their extractors, and those the sample queues they write to.
            state.mediaChunks.removeAll()
            return state.sampleQueues
        }
        queues.forEach { try? $0.preRelease() }
        // The playlist it played stops reloading by itself.
        chunkSource.reset()
        loader.release {
            queues.forEach { try? $0.release() }
        }
    }

    // MARK: - Track selection

    /// Gives the stream of a track group a new selection, keeping what it buffered: the chunks to come follow it.
    func replaceTrackSelection(_ selection: SETrackSelection, trackGroupIndex: Int) {
        guard trackGroupIndex == primaryTrackGroupIndex else { return }
        chunkSource.trackSelection = selection
    }

    /// Selects tracks, as ``MediaPeriod/selectTrack(selections:mayRetainStreamFlags:streams:streamResetFlags:position:)``
    /// does for the wrapper's track groups.
    ///
    /// - Returns: Whether the wrapper had to seek, resetting its sample queues.
    func selectTracks(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime,
        forceReset: Bool
    ) throws -> Bool {
        try stateLock.withLock { state in
            assert(state.isPrepared)
            let oldEnabledTrackGroupCount = state.enabledTrackGroupCount

            for index in selections.indices {
                guard let stream = streams[index] as? HlsSampleStream,
                      selections[index] == nil || !mayRetainStreamFlags[index] else {
                    continue
                }
                state.enabledTrackGroupCount -= 1
                unbind(&state, stream: stream)
                streams[index] = nil
            }

            let oldPrimaryTrackSelection = chunkSource.trackSelection
            // A stream kept for a new selection of its group: the chunks to come follow the new selection, and the
            // check below replaces what was buffered for the old one.
            for (index, selection) in selections.enumerated() {
                guard let selection, let stream = streams[index] as? HlsSampleStream,
                      stream.trackGroupIndex == state.primaryTrackGroupIndex,
                      state.trackGroups.firstIndex(of: selection.trackGroup) == stream.trackGroupIndex else {
                    continue
                }
                chunkSource.trackSelection = selection
            }
            var forceReset = forceReset
            var seekRequired = forceReset || (state.seenFirstTrackSelection
                ? oldEnabledTrackGroupCount == 0
                : position != state.lastSeekPosition)

            for (index, selection) in selections.enumerated() {
                guard let selection, streams[index] == nil,
                      let trackGroupIndex = state.trackGroups.firstIndex(of: selection.trackGroup) else {
                    continue
                }
                if trackGroupIndex == state.primaryTrackGroupIndex {
                    chunkSource.trackSelection = selection
                }

                let stream = HlsSampleStream(wrapper: self, trackGroupIndex: trackGroupIndex)
                state.streams.append(Weak(stream))
                streams[index] = stream
                streamResetFlags[index] = true
                state.enabledTrackGroupCount += 1

                if case let .bound(sampleQueueIndex) = bind(&state, trackGroupIndex: trackGroupIndex), !seekRequired {
                    let sampleQueue = state.sampleQueues[sampleQueueIndex]
                    seekRequired = sampleQueue.getReadIndex() != 0
                        && !sampleQueue.seek(time: position, allowTimeBeyondBuffer: true)
                }
            }

            if state.enabledTrackGroupCount == 0 {
                chunkSource.reset()
                state.mediaChunks.removeAll()
                if loader.isLoading() {
                    if state.sampleQueuesBuilt { try state.sampleQueues.forEach { try $0.discardToEnd() } }
                    loader.cancelLoading()
                } else {
                    try resetSampleQueues(&state)
                }
            } else {
                // The buffered chunks were loaded for the old primary selection. A new one replaces them, unless it
                // is the first selection and would load the same variant.
                if let newPrimaryTrackSelection = chunkSource.trackSelection, let lastChunk = state.mediaChunks.last,
                   oldPrimaryTrackSelection.map({ !$0.isEquals(to: newPrimaryTrackSelection) }) ?? true {
                    var primarySampleQueueDirty = true
                    if !state.seenFirstTrackSelection {
                        newPrimaryTrackSelection.updateSelectedTrack(
                            playbackPosition: position,
                            bufferedDuration: .zero,
                            availableDuration: .invalid,
                            queue: state.mediaChunks,
                            mediaChunkIterators: []
                        )
                        primarySampleQueueDirty = newPrimaryTrackSelection.selectedIndexInTrackGroup
                            != chunkSource.trackIndex(of: lastChunk.playlistUrl)
                    }
                    if primarySampleQueueDirty {
                        forceReset = true
                        seekRequired = true
                    }
                }
                if seekRequired {
                    _ = try seek(&state, position: position, forceReset: forceReset)
                    for index in streams.indices where streams[index] != nil {
                        streamResetFlags[index] = true
                    }
                }
            }

            state.seenFirstTrackSelection = true
            return seekRequired
        }
    }

    // MARK: - Seeking and buffer

    /// Seeks to the position.
    ///
    /// - Parameter forceReset: Whether to drop the buffer even if the position is in it.
    /// - Returns: Whether the sample queues were reset, rather than seeked within.
    func seek(to position: CMTime, forceReset: Bool) throws -> Bool {
        try stateLock.withLock { try seek(&$0, position: position, forceReset: forceReset) }
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) throws {
        try stateLock.withLock { state in
            guard state.sampleQueuesBuilt, !isPendingReset(state) else {
                return
            }
            for (index, sampleQueue) in state.sampleQueues.enumerated() {
                try sampleQueue.discard(
                    toTime: position,
                    to: toKeyframe,
                    stopAtReadPosition: state.sampleQueuesEnabledStates[index]
                )
            }
            // The chunk source only needs the last chunk; the earlier ones go once played.
            while state.mediaChunks.count > 1, state.mediaChunks[0].endTime <= position {
                state.mediaChunks.removeFirst()
            }
        }
    }

    /// The position of a sync sample near the position: segments start with one when they are independent.
    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        chunkSource.getAdjustedSeekPosition(position: position, seekParameters: seekParameters)
    }

    // MARK: - Loading

    func getBufferedPosition() -> CMTime {
        stateLock.withLock { state in
            if state.loadingFinished { return .positiveInfinity }
            if isPendingReset(state) { return state.pendingResetPosition }

            var bufferedPosition = state.lastSeekPosition
            let lastCompletedChunk = state.mediaChunks.last(where: \.isLoadCompleted)
            if let lastCompletedChunk {
                bufferedPosition = max(bufferedPosition, lastCompletedChunk.endTime)
            }
            if state.sampleQueuesBuilt {
                for sampleQueue in state.sampleQueues {
                    bufferedPosition = max(bufferedPosition, sampleQueue.getLargestQueuedTimestamp())
                }
            }
            return bufferedPosition
        }
    }

    func getNextLoadPosition() -> CMTime {
        stateLock.withLock { state in
            if isPendingReset(state) { return state.pendingResetPosition }
            if state.loadingFinished { return .positiveInfinity }
            return state.mediaChunks.last?.endTime ?? state.lastSeekPosition
        }
    }

    @discardableResult
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        withState { state, effects in
            guard !state.released, !state.loadingFinished, !loader.isLoading(), !loader.hasFatalError() else {
                return false
            }

            let chunkQueue: [HlsMediaChunk]
            let loadPosition: CMTime
            if isPendingReset(state) {
                chunkQueue = []
                loadPosition = state.pendingResetPosition
                state.sampleQueues.forEach { $0.setStartTime(state.pendingResetPosition) }
            } else {
                chunkQueue = state.mediaChunks
                let lastChunk = state.mediaChunks.last
                loadPosition = if let lastChunk {
                    lastChunk.isLoadCompleted ? lastChunk.endTime : max(state.lastSeekPosition, lastChunk.startTime)
                } else {
                    state.lastSeekPosition
                }
            }

            let largestReadPosition = state.sampleQueues
                .map { $0.getLargestReadTimestamp() }
                .filter(\.isNumeric)
                .max()
            let holder = chunkSource.getNextChunk(
                playbackPosition: loadingInfo.playbackPosition,
                loadPosition: loadPosition,
                largestReadPosition: largestReadPosition ?? .invalid,
                queue: chunkQueue,
                allowEndOfStream: state.isPrepared || !chunkQueue.isEmpty
            )

            if holder.endOfStream {
                SELogger.debug(.hls, "HLS \(uid) loaded to the end")
                state.pendingResetPosition = .invalid
                state.loadingFinished = true
                state.sampleQueues.forEach { $0.setLoadingFinished(true) }
                effects.append(.continueLoadingRequested)
                return true
            }

            guard let chunk = holder.chunk else {
                if let playlistUrl = holder.playlistUrl {
                    effects.append(.playlistRefreshRequired(playlistUrl))
                }
                return false
            }

            if let mediaChunk = chunk as? HlsMediaChunk {
                maybeDiscardUpstreamForNewMediaChunk(&state, newChunk: mediaChunk)
                state.pendingResetPosition = .invalid
                mediaChunk.initialize(output: self)
                mediaChunk.firstSampleIndices = state.sampleQueues.map { $0.getWriteIndex() }
                state.mediaChunks.append(mediaChunk)
            }
            loader.startLoading(
                loadable: chunk,
                callback: self,
                defaultMinRetryCount: loadErrorHandlingPolicy.getMinimumLoadableRetryCount(dataType: chunk.dataType)
            )
            return true
        }
    }

    /// Drops queued chunks the playlist replaced, and those the selection would rather load again in a better
    /// quality.
    func reevaluateBuffer(position: CMTime) {
        stateLock.withLock { state in
            guard !state.released, !loader.hasFatalError(), !isPendingReset(state), !loader.isLoading() else {
                return
            }
            var queueSize = state.mediaChunks.count
            while queueSize > 0, chunkSource.publicationState(of: state.mediaChunks[queueSize - 1]) == .removed {
                queueSize -= 1
            }
            if queueSize < state.mediaChunks.count {
                discardUpstream(&state, preferredQueueSize: queueSize)
            }
            let preferredQueueSize = min(
                state.mediaChunks.count,
                chunkSource.preferredQueueSize(playbackPosition: position, queue: state.mediaChunks)
            )
            if preferredQueueSize < state.mediaChunks.count {
                discardUpstream(&state, preferredQueueSize: preferredQueueSize)
            }
        }
    }

    /// Whether only the frame at the position is needed, as while the user scrubs a paused player.
    func setScrubbing(_ isScrubbing: Bool) {
        chunkSource.isScrubbing = isScrubbing
    }

    // MARK: - Sample streams

    func bindSampleQueue(trackGroupIndex: Int) -> SampleQueueBinding {
        stateLock.withLock { bind(&$0, trackGroupIndex: trackGroupIndex) }
    }

    func isReady(sampleQueueIndex: Int) -> Bool {
        stateLock.withLock { state in
            guard !isPendingReset(state) else { return false }
            return state.sampleQueues[sampleQueueIndex].isReady(loadingFinished: state.loadingFinished)
        }
    }

    func bufferedAheadDuration(sampleQueueIndex: Int) -> CMTime {
        stateLock.withLock { $0.sampleQueues[sampleQueueIndex].bufferedAheadDuration }
    }

    func readData(sampleQueueIndex: Int, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        try stateLock.withLock { state in
            guard !isPendingReset(state) else { return .nothingRead }
            return try state.sampleQueues[sampleQueueIndex].read(
                readFlags: readFlags,
                loadingFinished: state.loadingFinished
            )
        }
    }

    func skipData(sampleQueueIndex: Int, position: CMTime) -> Int {
        stateLock.withLock { state in
            guard !isPendingReset(state) else { return 0 }
            let sampleQueue = state.sampleQueues[sampleQueueIndex]
            let skipCount = sampleQueue.getSkipCount(time: position, allowEndOfQueue: state.loadingFinished)
            sampleQueue.skip(count: skipCount)
            return skipCount
        }
    }

    func seekWithinBuffer(sampleQueueIndex: Int, position: CMTime) -> SampleStreamSeekResult {
        stateLock.withLock { state in
            guard !isPendingReset(state), state.sampleQueues.indices.contains(sampleQueueIndex) else {
                return .unavailable
            }
            return state.sampleQueues[sampleQueueIndex].seekWithinBuffer(to: position)
        }
    }

    func sampleQueue(at index: Int) -> SampleQueue {
        stateLock.withLock { $0.sampleQueues[index] }
    }

    func unbindSampleQueue(stream: HlsSampleStream) {
        stateLock.withLock { unbind(&$0, stream: stream) }
    }
}

// MARK: - Locked implementation

private extension HlsSampleStreamWrapper {
    func seek(_ state: inout State, position: CMTime, forceReset: Bool) throws -> Bool {
        state.lastSeekPosition = position
        if isPendingReset(state) {
            state.pendingResetPosition = position
            return true
        }

        if state.sampleQueuesBuilt, !forceReset, seekInsideBuffer(state, position: position) {
            SELogger.debug(.hls, "HLS \(uid) seeks to \(position.seconds) inside the buffer")
            return false
        }

        SELogger.debug(
            .hls,
            "HLS \(uid) seeks to \(position.seconds) outside the buffer"
                + (forceReset ? ", reset forced" : "")
                + (loader.isLoading() ? ", canceling the load" : "")
        )

        state.pendingResetPosition = position
        state.loadingFinished = false
        state.sampleQueues.forEach { $0.setLoadingFinished(false) }
        state.mediaChunks.removeAll()
        if loader.isLoading() {
            if state.sampleQueuesBuilt { try state.sampleQueues.forEach { try $0.discardToEnd() } }
            loader.cancelLoading()
        } else {
            loader.clearFatalError()
            try resetSampleQueues(&state)
        }
        return true
    }

    func seekInsideBuffer(_ state: State, position: CMTime) -> Bool {
        let haveAudioVideoSampleQueues = state.sampleQueueIsAudioVideo.contains(true)
        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            let seekInsideQueue = sampleQueue.seek(time: position, allowTimeBeyondBuffer: false)
            // A track of another type can lag behind: the audio and video decide.
            if !seekInsideQueue, state.sampleQueueIsAudioVideo[index] || !haveAudioVideoSampleQueues {
                return false
            }
        }
        return true
    }

    /// Before a new chunk loads: a last chunk the playlist never confirmed goes, and an independent chunk that starts
    /// where queued chunks start replaces them cleanly rather than splicing into them.
    func maybeDiscardUpstreamForNewMediaChunk(_ state: inout State, newChunk: HlsMediaChunk) {
        guard let lastChunk = state.mediaChunks.last else { return }
        if !lastChunk.isPublished {
            discardUpstream(&state, preferredQueueSize: state.mediaChunks.count - 1)
        }
        guard newChunk.isIndependent, newChunk.shouldSpliceIn else { return }
        for index in state.mediaChunks.indices.reversed() {
            let startTime = state.mediaChunks[index].startTime
            if startTime < newChunk.startTime { break }
            if startTime == newChunk.startTime, canDiscardUpstreamMediaChunks(state, from: index) {
                discardUpstream(&state, preferredQueueSize: index)
                newChunk.clearShouldSpliceIn()
                break
            }
        }
    }

    /// Drops the queued chunks from `preferredQueueSize` on, or from the first after it that nothing was read from,
    /// with their samples.
    func discardUpstream(_ state: inout State, preferredQueueSize: Int) {
        guard !loader.isLoading(), preferredQueueSize >= 0, preferredQueueSize < state.mediaChunks.count,
              let newQueueSize = (preferredQueueSize ..< state.mediaChunks.count)
                .first(where: { canDiscardUpstreamMediaChunks(state, from: $0) }) else {
            return
        }

        let firstRemoved = state.mediaChunks[newQueueSize]
        let removedCount = state.mediaChunks.count - newQueueSize
        SELogger.debug(.hls, "HLS \(uid) discards \(removedCount) chunks from \(firstRemoved.startTime.seconds)s")
        state.mediaChunks.removeSubrange(newQueueSize...)
        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            let firstSampleIndex = Self.firstSampleIndex(of: firstRemoved, sampleQueue: index)
            try? sampleQueue.discardUpstreamSamples(discardFromIndex: firstSampleIndex)
        }
        if let lastChunk = state.mediaChunks.last {
            // Its extractor read into what was discarded: the next chunk starts with a new one.
            lastChunk.invalidateExtractor()
        } else {
            state.pendingResetPosition = max(state.lastSeekPosition, firstRemoved.startTime)
        }
        state.loadingFinished = false
        state.sampleQueues.forEach { $0.setLoadingFinished(false) }
    }

    /// Whether the chunks from `index` on can go: none of them splices into what is before it, and the renderers read
    /// nothing of them yet.
    func canDiscardUpstreamMediaChunks(_ state: State, from index: Int) -> Bool {
        guard !state.mediaChunks[index...].contains(where: \.shouldSpliceIn) else {
            return false
        }
        let chunk = state.mediaChunks[index]
        for (queueIndex, sampleQueue) in state.sampleQueues.enumerated()
            where sampleQueue.getReadIndex() > Self.firstSampleIndex(of: chunk, sampleQueue: queueIndex) {
            return false
        }
        return true
    }

    /// The first sample a chunk wrote to a sample queue: 0 for a queue made after the chunk started.
    static func firstSampleIndex(of chunk: HlsMediaChunk, sampleQueue index: Int) -> Int {
        chunk.firstSampleIndices.indices.contains(index) ? chunk.firstSampleIndices[index] : 0
    }

    func resetSampleQueues(_ state: inout State) throws {
        try state.sampleQueues.forEach { try $0.reset() }
    }

    func isPendingReset(_ state: State) -> Bool {
        state.pendingResetPosition.isValid
    }

    func bind(_ state: inout State, trackGroupIndex: Int) -> SampleQueueBinding {
        guard let mapping = state.trackGroupToSampleQueueIndex else {
            return .pending
        }
        guard let sampleQueueIndex = mapping[trackGroupIndex] else {
            return .noMapping
        }
        state.sampleQueuesEnabledStates[sampleQueueIndex] = true
        return .bound(sampleQueueIndex)
    }

    func unbind(_ state: inout State, stream: HlsSampleStream) {
        state.streams.removeAll { $0.value == nil || $0.value === stream }
        guard let sampleQueueIndex = stream.boundSampleQueueIndex else {
            return
        }
        state.sampleQueuesEnabledStates[sampleQueueIndex] = false
    }

    func maybeFinishPrepare(_ state: inout State, effects: inout [Effect]) {
        guard !state.released, state.trackGroupToSampleQueueIndex == nil, state.sampleQueuesBuilt else {
            return
        }
        guard state.sampleQueues.allSatisfy({ $0.getUpstreamFormat() != nil }) else {
            return
        }

        if state.isPrepared {
            // Prepared from the multivariant playlist: only the mapping was missing.
            mapTrackGroupsToSampleQueues(&state)
            effects.append(.sampleQueuesMapped(state.streams.compactMap(\.value)))
        } else {
            buildTracksFromSampleStreams(&state)
            state.isPrepared = true
            effects.append(.prepared)
        }
    }

    func mapTrackGroupsToSampleQueues(_ state: inout State) {
        var mapping: [Int?] = Array(repeating: nil, count: state.trackGroups.count)
        var usedSampleQueues = Set<Int>()
        for (groupIndex, group) in state.trackGroups.enumerated() {
            let manifestFormat = group.getFormat(index: 0)
            let queueIndex = state.sampleQueues.indices.first { queueIndex in
                guard !usedSampleQueues.contains(queueIndex),
                      let sampleFormat = state.sampleQueues[queueIndex].getUpstreamFormat() else {
                    return false
                }
                return Self.formatsMatch(
                    manifestFormat: manifestFormat,
                    sampleFormat: sampleFormat,
                    sampleTrackType: state.sampleQueueTypes[queueIndex]
                )
            }
            guard let queueIndex else { continue }
            mapping[groupIndex] = queueIndex
            usedSampleQueues.insert(queueIndex)
        }
        state.trackGroupToSampleQueueIndex = mapping
    }

    /// Builds the track groups from the sample formats: the primary track takes the variants' formats, the others
    /// their own.
    func buildTracksFromSampleStreams(_ state: inout State) {
        func rank(_ type: TrackType) -> Int {
            switch type {
            case .video: 3
            case .audio: 2
            case .text: 1
            default: 0
            }
        }

        var primaryExtractorTrackType = TrackType.unknown
        var primaryExtractorTrackIndex: Int?
        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            let type = sampleQueue.getUpstreamFormat()?.trackType ?? .unknown
            if rank(type) > rank(primaryExtractorTrackType) {
                primaryExtractorTrackType = type
                primaryExtractorTrackIndex = index
            } else if type == primaryExtractorTrackType, primaryExtractorTrackIndex != nil {
                // Two primary tracks of one type: none of them can be matched to the variants.
                primaryExtractorTrackIndex = nil
            }
        }

        let chunkSourceTrackGroup = chunkSource.trackGroup
        var trackGroups: [TrackGroup] = []
        for (index, sampleQueue) in state.sampleQueues.enumerated() {
            guard let sampleFormat = sampleQueue.getUpstreamFormat() else {
                continue
            }
            let formats: [AnyFormat]
            if index == primaryExtractorTrackIndex {
                formats = chunkSourceTrackGroup.map {
                    Self.deriveFormat(playlistFormat: $0, sampleFormat: sampleFormat, propagateBitrates: true)
                }
                state.primaryTrackGroupIndex = index
            } else {
                let isMuxedAudio = primaryExtractorTrackType == .video && sampleFormat.trackType == .audio
                let format = Self.deriveFormat(
                    playlistFormat: isMuxedAudio ? muxedAudioFormat : nil,
                    sampleFormat: sampleFormat,
                    propagateBitrates: false
                )
                formats = [format]
            }
            if let group = try? TrackGroup(id: "\(uid):\(index)", formats: formats) {
                trackGroups.append(group)
            }
        }

        state.trackGroups = TrackGroupArray(trackGroups: trackGroups)
        state.trackGroupToSampleQueueIndex = Array(state.sampleQueues.indices)
    }

    /// - Parameter sampleTrackType: The type the extractor declared the track with: it is known even when the
    ///   sample format has no MIME type.
    static func formatsMatch(manifestFormat: AnyFormat, sampleFormat: AnyFormat, sampleTrackType: TrackType) -> Bool {
        guard manifestFormat.trackType == sampleTrackType else { return false }
        if let manifestText = manifestFormat.text {
            // Closed captions of one video tell their channels apart.
            let sampleCodec = sampleFormat.text?.codec
            return manifestText.codec?.mimeType == sampleCodec?.mimeType
                && manifestText.codec?.cea608 == sampleCodec?.cea608
                && manifestText.codec?.cea708 == sampleCodec?.cea708
        }
        return true
    }

    /// The type of the samples a playlist format describes: the video of a variant that has some, else audio.
    static func primaryType(of playlistFormat: AnyFormat) -> TrackType {
        let hasSize = playlistFormat.video?.size != nil
        return hasSize || Codecs.ofType(playlistFormat.codecs, trackType: .video) != nil ? .video : .audio
    }

    /// The format of the samples, with what the playlist says about the rendition.
    static func deriveFormat(playlistFormat: AnyFormat?, sampleFormat: AnyFormat, propagateBitrates: Bool) -> AnyFormat {
        guard let playlistFormat else { return sampleFormat }
        var format = sampleFormat
        format.label = playlistFormat.label
        format.language = playlistFormat.language
        format.selectionFlags = playlistFormat.selectionFlags
        format.roleFlags = playlistFormat.roleFlags
        format.averageBitrate = propagateBitrates ? playlistFormat.averageBitrate : nil
        format.peakBitrate = propagateBitrates ? playlistFormat.peakBitrate : nil
        if let id = playlistFormat.id {
            format.id = id
        }
        if let codecs = Codecs.ofType(playlistFormat.codecs, trackType: sampleFormat.trackType) {
            format.codecs = codecs
        }
        if let size = playlistFormat.video?.size {
            format.video?.size = size
            if let frameRate = playlistFormat.video?.frameRate, frameRate > 0 {
                format.video?.frameRate = frameRate
            }
        }
        if let channelCount = playlistFormat.audio?.channelCount, channelCount > 0 {
            format.audio?.channelCount = channelCount
        }
        return format
    }

    func makeTrackOutput(_ state: inout State, id: Int, trackType: TrackType) throws -> TrackOutput {
        let isMappable = Self.mappableTypes.contains(trackType)
        if isMappable, let index = state.sampleQueueIndicesByType[trackType] {
            // The track of a type keeps its sample queue across chunks, whatever its id in the new chunk.
            if state.sampleQueueMappingDoneByType.insert(trackType).inserted {
                state.sampleQueueTrackIds[index] = id
            }
            return state.sampleQueueTrackIds[index] == id ? state.sampleQueues[index] : DiscardingTrackOutput()
        } else if !isMappable, let index = state.sampleQueueTrackIds.indices.first(where: {
            state.sampleQueueTrackIds[$0] == id && state.sampleQueueTypes[$0] == trackType
        }) {
            return state.sampleQueues[index]
        }

        // Tracks that appear after preparation have nowhere to go.
        if state.tracksEnded {
            return DiscardingTrackOutput()
        }

        let sampleQueue = try HlsSampleQueue(queue: queue, bufferedBytesCounter: bufferedBytesCounter)
        sampleQueue.delegate = self
        // Samples go once the renderer has read this far past them. The player discards behind playback only when it
        // updates, which can be rare while playback runs.
        sampleQueue.backBufferDuration = SampleQueue.readBackBufferDuration
        if let playlistFormat = state.loadingPlaylistFormat, Self.primaryType(of: playlistFormat) == trackType {
            sampleQueue.setPlaylistFormat(playlistFormat)
        }
        let index = state.sampleQueues.count
        state.sampleQueues.append(sampleQueue)
        state.sampleQueueTrackIds.append(id)
        state.sampleQueueTypes.append(trackType)
        state.sampleQueuesEnabledStates.append(false)
        state.sampleQueueIsAudioVideo.append(trackType == .audio || trackType == .video)
        if isMappable {
            state.sampleQueueIndicesByType[trackType] = index
            state.sampleQueueMappingDoneByType.insert(trackType)
        }
        return sampleQueue
    }
}

private extension HlsSampleStreamWrapper {
    /// How soon a preload hint that the server doesn't have is asked for again.
    static let preloadHintRetryDelay = DispatchTimeInterval.milliseconds(250)
    /// The types whose track keeps its sample queue from chunk to chunk, whatever its id in the chunk.
    static let mappableTypes: Set<TrackType> = [.audio, .video, .metadata]
}

// MARK: - Critical section and deferred effects

private extension HlsSampleStreamWrapper {
    enum Effect {
        case prepared
        case continueLoadingRequested
        case playlistRefreshRequired(URL)
        case sampleQueuesMapped([HlsSampleStream])
    }

    @inline(__always)
    func withState<R>(_ body: (inout State, inout [Effect]) throws -> R) rethrows -> R {
        var effects: [Effect] = []
        defer { deliver(effects) }
        return try stateLock.withLock { state in try body(&state, &effects) }
    }

    func deliver(_ effects: [Effect]) {
        guard !effects.isEmpty else { return }
        // Always later: callers on the player queue are still in the middle of what produced the effects.
        queue.justDispatch { [weak self] in
            guard let self else { return }
            for effect in effects {
                switch effect {
                case .prepared:
                    callback?.onPrepared(self)
                case .continueLoadingRequested:
                    callback?.continueLoadingRequested(self)
                case let .playlistRefreshRequired(url):
                    callback?.onPlaylistRefreshRequired(url: url)
                case let .sampleQueuesMapped(streams):
                    streams.forEach { $0.sampleQueuesDidMap() }
                }
            }
        }
    }
}

// MARK: - Loader.Callback

extension HlsSampleStreamWrapper: Loader.Callback {
    func onLoadStarted(loadable: Chunk, onTime: DispatchTime, loadDuration: DispatchTimeInterval, retryCount: Int) {}

    func onLoadCompleted(loadable: Chunk, onTime: DispatchTime, loadDuration: DispatchTimeInterval) {
        let name = loadable.dataSpec.url.lastPathComponent
        SELogger.debug(
            .hls,
            "HLS \(uid) loaded \(name), \(loadable.bytesLoaded) bytes, in \(loadDuration.totalMilliseconds)ms"
        )
        chunkSource.onChunkLoadCompleted(loadable)
        let isPrepared = stateLock.withLock { $0.isPrepared }
        if isPrepared {
            callback?.continueLoadingRequested(self)
        } else {
            continuePreparing()
        }
    }

    func onLoadCancelled(loadable: Chunk, onTime: DispatchTime, loadDuration: DispatchTimeInterval, released: Bool) {
        let name = loadable.dataSpec.url.lastPathComponent
        SELogger.debug(
            .hls,
            "HLS \(uid) canceled \(name) after \(loadDuration.totalMilliseconds)ms\(released ? ", released" : "")"
        )
        guard !released else { return }
        let shouldContinue = stateLock.withLock { state -> Bool in
            if isPendingReset(state) || state.enabledTrackGroupCount == 0 {
                try? resetSampleQueues(&state)
            } else if let chunk = loadable as? HlsMediaChunk, state.mediaChunks.last === chunk,
                      chunkSource.publicationState(of: chunk) == .removed {
                // A preload hint the playlist replaced: what it loaded goes.
                discardUpstream(&state, preferredQueueSize: state.mediaChunks.count - 1)
            }
            return state.enabledTrackGroupCount > 0
        }
        if shouldContinue {
            callback?.continueLoadingRequested(self)
        }
    }

    func onLoadError(
        loadable: Chunk,
        onTime: DispatchTime,
        loadDuration: DispatchTimeInterval,
        error: Error,
        errorCount: Int
    ) -> Loader.LoadErrorAction {
        // A server answers 404, or 410, for a preload hint it replaced: the playlist update that tells it cancels the
        // load, and until then the part is asked for again.
        let name = loadable.dataSpec.url.lastPathComponent
        let responseCode = (error as? InvalidResponseCodeError)?.responseCode
        if let mediaChunk = loadable as? HlsMediaChunk, !mediaChunk.isPublished,
           let responseCode, responseCode == 404 || responseCode == 410 {
            SELogger.debug(.hls, "HLS \(uid) preload hint \(name) answered \(responseCode): asking again")
            mediaChunk.prepareForRetry()
            return .createRetryAction(resetErrorCount: false, retryDelay: Self.preloadHintRetryDelay)
        }

        let errorInfo = LoadErrorInfo(dataType: loadable.dataType, error: error, errorCount: errorCount)

        // Another variant may load where this one fails, as when the server lost it.
        let fallback = loadErrorHandlingPolicy.getFallbackSelection(
            for: chunkSource.fallbackOptions(),
            loadErrorInfo: errorInfo
        )
        var exclusionSucceeded = false
        if let fallback, fallback.type == .track {
            exclusionSucceeded = chunkSource.maybeExcludeTrack(
                of: loadable,
                exclusionDuration: fallback.exclusionDuration
            )
        }

        if exclusionSucceeded {
            SELogger.warning(.hls, "HLS \(uid) excluded the track of \(name): \(error)")
            let isPrepared = withState { state, effects in
                // A chunk that loaded nothing goes: the next one loads from the new track instead.
                if let mediaChunk = loadable as? HlsMediaChunk, mediaChunk.bytesLoaded == 0,
                   state.mediaChunks.last === mediaChunk {
                    state.mediaChunks.removeLast()
                    if state.mediaChunks.isEmpty {
                        state.pendingResetPosition = max(state.lastSeekPosition, mediaChunk.startTime)
                    }
                }
                if state.isPrepared {
                    effects.append(.continueLoadingRequested)
                }
                return state.isPrepared
            }
            if !isPrepared {
                queue.justDispatch { [weak self] in self?.continuePreparing() }
            }
            return .dontRetry
        }

        guard let retryDelay = loadErrorHandlingPolicy.getRetryDelay(for: errorInfo) else {
            SELogger.error(.hls, "HLS \(uid) chunk \(name) failed with a fatal error, not retrying: \(error)")
            // Nothing loads any more: the player looks for the error without waiting for the buffer to run out.
            withState { _, effects in effects.append(.continueLoadingRequested) }
            return .dontRetryFatal
        }
        SELogger.warning(
            .hls,
            "HLS \(uid) chunk \(name) failed (attempt \(errorCount)), "
                + "retrying in \(retryDelay.totalMilliseconds)ms: \(error)"
        )
        // A retried media chunk starts over and splices its samples into those it already queued.
        if let mediaChunk = loadable as? HlsMediaChunk {
            mediaChunk.prepareForRetry()
        }
        return .createRetryAction(resetErrorCount: false, retryDelay: retryDelay)
    }
}

// MARK: - HlsMediaChunkOutput

extension HlsSampleStreamWrapper: HlsMediaChunkOutput {
    func prepare(chunkUid: Int, shouldSpliceIn: Bool, reusingExtractor: Bool) {
        stateLock.withLock { state in
            if !reusingExtractor {
                state.sampleQueueMappingDoneByType.removeAll()
            }
            // The samples of the chunk tell which variant or rendition they are of, also when the extractor goes on
            // from the previous one.
            let playlistFormat = state.mediaChunks.last(where: { $0.uid == chunkUid })?.trackFormat
            state.loadingPlaylistFormat = playlistFormat
            if let playlistFormat, let index = state.sampleQueueIndicesByType[Self.primaryType(of: playlistFormat)] {
                (state.sampleQueues[index] as? HlsSampleQueue)?.setPlaylistFormat(playlistFormat)
            }
            if shouldSpliceIn {
                state.sampleQueues.forEach { $0.splice() }
            }
        }
    }

    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        try stateLock.withLock { try makeTrackOutput(&$0, id: id, trackType: trackType) }
    }

    func endTracks() {
        withState { state, effects in
            state.tracksEnded = true
            state.sampleQueuesBuilt = true
            maybeFinishPrepare(&state, effects: &effects)
        }
    }

    func seekMap(seekMap: SeekMap) {
        // Segments are found through the playlist.
    }
}

// MARK: - SampleQueueDelegate

extension HlsSampleStreamWrapper: SampleQueueDelegate {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: AnyFormat) {
        withState { state, effects in maybeFinishPrepare(&state, effects: &effects) }
    }
}

// MARK: - State

private extension HlsSampleStreamWrapper {
    struct State {
        var sampleQueues: [SampleQueue] = []
        var sampleQueueTrackIds: [Int] = []
        var sampleQueueTypes: [TrackType] = []
        var sampleQueuesEnabledStates: [Bool] = []
        var sampleQueueIsAudioVideo: [Bool] = []
        var sampleQueueIndicesByType: [TrackType: Int] = [:]
        var sampleQueueMappingDoneByType: Set<TrackType> = []
        var sampleQueuesBuilt = false
        var tracksEnded = false

        var mediaChunks: [HlsMediaChunk] = []
        /// The variant or rendition of the chunk loading.
        var loadingPlaylistFormat: AnyFormat?
        var streams: [Weak<HlsSampleStream>] = []

        var isPrepared = false
        var trackGroups: TrackGroupArray = .empty
        var primaryTrackGroupIndex = 0
        var trackGroupToSampleQueueIndex: [Int?]?
        var enabledTrackGroupCount = 0
        var seenFirstTrackSelection = false

        var lastSeekPosition: CMTime = .zero
        var pendingResetPosition: CMTime = .invalid
        var loadingFinished = false
        var released = false
    }

    struct Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
}

/// A sample queue whose formats carry what the playlist says about the variant or rendition of their samples: its id,
/// label and bitrates, which the media itself doesn't. A switch of variant then reads as a change of format, at the
/// first sample of the new variant.
final class HlsSampleQueue: SampleQueue, @unchecked Sendable {
    private let playlistFormatLock = UnfairLock()
    private var playlistFormat: AnyFormat? // Guarded by playlistFormatLock.

    /// The playlist format of what loads from now on.
    func setPlaylistFormat(_ format: AnyFormat) {
        let changed = playlistFormatLock.withLock { () -> Bool in
            guard playlistFormat != format else { return false }
            playlistFormat = format
            return true
        }
        if changed { invalidateUpstreamFormatAdjustment() }
    }

    override func getAdjustedUpstreamFormat(_ format: AnyFormat) -> AnyFormat {
        let playlistFormat = playlistFormatLock.withLock { self.playlistFormat }
        var derived = HlsSampleStreamWrapper.deriveFormat(
            playlistFormat: playlistFormat,
            sampleFormat: format,
            propagateBitrates: true
        )
        // The size of the samples goes into their format description, which the decoder takes the picture size from:
        // the playlist's can differ, as that of the variant an I-frame stands for.
        if let size = format.video?.size {
            derived.video?.size = size
        }
        return super.getAdjustedUpstreamFormat(derived)
    }
}

/// Takes samples of tracks no sample queue reads, and drops them.
final class DiscardingTrackOutput: TrackOutput {
    func setFormat(_ format: AnyFormat) throws {}
    func sampleData(data: CMBlockBuffer) throws {}
    func sampleMetadata(_ properties: SampleProperties) throws {}
}
