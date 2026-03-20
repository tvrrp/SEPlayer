//
//  ProgressiveMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import DataSource
import Decoder
import Foundation
import Extractor
import SEPlayerCommon

final class ProgressiveMediaPeriod: MediaPeriod {
    protocol Listener: AnyObject {
        func sourceInfoRefreshed(duration: CMTime, seekMap: SeekMap, isLive: Bool)
    }

    var trackGroups: TrackGroupArray { trackState.tracks }
    var isLoading: Bool { queue.sync { loader.isLoading() && loadCondition.isOpen } }

    private let queue: Queue
    private let loaderSyncActor: PlayerActor
    private let url: URL
    private let dataSource: DataSource
    private weak var listener: Listener?
    private let allocator: Allocator
    private let continueLoadingCheckIntervalBytes: Int
    private let loader: Loader
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let loadCondition: AsyncConditionVariable

    private var callback: (any MediaPeriodCallback)?
    private var sampleQueues: [TriggerableSampleQueue] = []
    private var sampleQueueTrackIds: [Int] = []
    private var sampleQueuesBuild: Bool = false

    private var isPrepared: Bool = false
    private var haveAudioVideoTracks: Bool = false
    private var isSingleSample: Bool = false
    private var trackState = TrackState.empty
    private var seekMap: SeekMap?
    private var duration: CMTime = .zero
    private var isLive: Bool = false

    private var seenFirstTrackSelection: Bool = false
    private var notifyDiscontinuity: Bool = false
    private var pendingInitialDiscontinuity: Bool = false
    private var enabledTrackCount = 0
    private var isLengthKnown: Bool = true

    private var lastSeekPosition: CMTime = .zero
    private var pendingResetPosition: CMTime = .invalid
    private var pendingDeferredRetry: Bool = false

    private var extractedSamplesCountAtStartOfLoad = 0
    private var loadingFinished: Bool = false
    private var didRelease: Bool = false

    init(
        url: URL,
        queue: Queue,
        loadQueue: Queue,
        dataSource: DataSource,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        listener: Listener,
        allocator: Allocator,
        continueLoadingCheckIntervalBytes: Int
    ) {
        self.url = url
        self.queue = queue
        self.loaderSyncActor = loadQueue.playerActor()
        self.dataSource = dataSource
        self.loader = Loader(workQueue: queue, loadQueue: loadQueue)
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.loadCondition = AsyncConditionVariable()
        self.listener = listener
        self.allocator = allocator
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
    }

    func release() {
        if isPrepared {
            sampleQueues.forEach { $0.preRelease() }
        }

        loader.release { [weak self] in
            guard let self else { return }
            queue.async { self.onLoaderReleased() }
        }

        callback = nil
        seekMap = nil
        didRelease = true
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        self.callback = callback
        loadCondition.open()
        startLoading()
    }

    func maybeThrowPrepareError() throws {
        try maybeThrowError()
        if loadingFinished && !isPrepared {
            // TODO: parser error
            throw ErrorBuilder(errorDescription: "Loading finished before preparation is complete.")
        }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [TriggerableSampleStream?],
        streamResetFlags: inout [Bool],
        position: CMTime
    ) -> CMTime {
        assertPrepared()
        var position = position
        let tracks = trackState.tracks
        var trackEnabledStates = trackState.trackEnabledState
        let oldEnabledTrackCount = enabledTrackCount

        for index in 0..<selections.count {
            if streams[index] != nil, selections[index] == nil || !mayRetainStreamFlags[index] {
                let track = (streams[index] as! SampleStreamHolder).track
                assert(trackEnabledStates[track])
                enabledTrackCount -= 1
                trackEnabledStates[index] = false
                streams[index] = nil
            }
        }

        var seekRequired = seenFirstTrackSelection ? oldEnabledTrackCount == 0 : position != .zero

        for (index, selection) in selections.enumerated() {
            if let selection, streams[index] == nil {
                if let trackIndex = tracks.firstIndex(of: selection.trackGroup)  {
                    streams[index] = SampleStreamHolder(
                        track: trackIndex,
                        handlers: .init(
                            isReadyClosure: isReady,
                            errorClosure: maybeThrowError,
                            readDataClosure: readData,
                            skipDataClosure: skipData,
                            installTrigger: installTrigger,
                            removeTrigger: removeTrigger,
                            testTrigger: testTrigger
                        )
                    )
                    enabledTrackCount += 1
                    trackEnabledStates[index] = true
                    streamResetFlags[index] = true

                    if !seekRequired {
                        let sampleQueue = sampleQueues[index]
                        seekRequired = sampleQueue.getReadIndex() != 0
                            && !sampleQueue.seek(time: position, allowTimeBeyondBuffer: true)
                    }
                } else {
                    streams[index] = nil
                    continue
                }
            }
        }

        if enabledTrackCount == 0 {
            pendingDeferredRetry = false
            notifyDiscontinuity = false
            pendingInitialDiscontinuity = false
            if loader.isLoading() {
                sampleQueues.forEach { $0.discardToEnd() }
                loader.cancelLoading()
            } else {
                loadingFinished = false
                sampleQueues.forEach { $0.reset() }
            }
        } else if seekRequired {
            position = seek(position: position)
            for index in 0..<streams.count {
                if streams[index] != nil { streamResetFlags[index] = true }
            }
        }

        trackState.trackEnabledState = trackEnabledStates
        seenFirstTrackSelection = true
        return position
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) {
        assertPrepared()
        guard !isPendingReset() else { return }

        let trackEnabledStates = trackState.trackEnabledState

        for (index, sampleQueue) in sampleQueues.enumerated() {
            sampleQueue.discard(toTime: position, to: toKeyframe, stopAtReadPosition: trackEnabledStates[index])
        }
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        if loadingFinished
            || pendingDeferredRetry
            || isPrepared && enabledTrackCount == 0 {
            return false
        }

        var continuedLoading = loadCondition.open()
        if !loader.isLoading() {
            startLoading()
            continuedLoading = true
        }
        return continuedLoading
    }

    func getNextLoadPosition() -> CMTime {
        getBufferedPosition()
    }

    func readDiscontinuity() -> CMTime {
        if pendingInitialDiscontinuity {
            pendingInitialDiscontinuity = false
            return lastSeekPosition
        }

        if notifyDiscontinuity,
           (loadingFinished || getExtractedSamplesCount() > extractedSamplesCountAtStartOfLoad) {
            notifyDiscontinuity = false
            return lastSeekPosition
        }

        return .invalid
    }

    func getBufferedPosition() -> CMTime {
        assertPrepared()
        if loadingFinished || enabledTrackCount == 0 {
            return .positiveInfinity
        } else if isPendingReset() {
            return pendingResetPosition
        }

        var largestQueuedTimestamp = CMTime.positiveInfinity
        if haveAudioVideoTracks {
            for (index, sampleQueue) in sampleQueues.enumerated() {
                if trackState.isAudioOrVideo[index],
                   trackState.trackEnabledState[index],
                   !sampleQueue.lastSampleQueued() {
                    largestQueuedTimestamp = min(largestQueuedTimestamp, sampleQueue.getLargestQueuedTimestamp())
                }
            }
        }

        if largestQueuedTimestamp.isPositiveInfinity {
            largestQueuedTimestamp = getLargestQueuedTimestamp(includeDisabledTracks: false)
        }

        return largestQueuedTimestamp.isNegativeInfinity ? lastSeekPosition : largestQueuedTimestamp
    }

    func seek(position: CMTime) -> CMTime {
        assertPrepared()
        guard let seekMap else { return .zero }
        let trackIsAudioVideoFlags = trackState.isAudioOrVideo
        let position = seekMap.isSeekable() ? position : .zero

        notifyDiscontinuity = false
        let isSameAsLastSeekPosition = lastSeekPosition == position
        lastSeekPosition = position
        if isPendingReset() {
            pendingResetPosition = position
            return position
        }

        print("🥵 seek(to position = \(position)")
        if (loadingFinished || loader.isLoading())
           && seekInsideBuffer(isAudioOrVideo: trackIsAudioVideoFlags,
                                 position: position,
                                 isSameAsLastSeekPosition: isSameAsLastSeekPosition) {
            return position
        }

        pendingDeferredRetry = false
        pendingResetPosition = position
        loadingFinished = false
        pendingInitialDiscontinuity = false

        if loader.isLoading() {
            sampleQueues.forEach { $0.discardToEnd() }
            loader.cancelLoading()
        } else {
            sampleQueues.forEach { $0.reset() }
        }

        return position
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        assertPrepared()
        guard let seekMap, seekMap.isSeekable() else {
            return .zero
        }

        let seekPoints = seekMap.getSeekPoints(for: position)
        let position = seekParameters.resolveSyncPosition(
            position: position,
            firstSync: seekPoints.first.time,
            secondSync: seekPoints.second.time
        )
        print("❌ adjustedSeekPositionUs = \(position)")
        return position
    }

    func isReady(track: Int) -> Bool {
        assert(queue.isCurrent())
        return !suppressRead() && sampleQueues[track].isReady(loadingFinished: loadingFinished) == true
    }

    func maybeThrowError(sampleQueueIndex: Int) throws {
        try sampleQueues[sampleQueueIndex].maybeThrowError()
        try maybeThrowError()
    }

    func maybeThrowError() throws {
        try loader.maybeThrowError() // TODO: min retry count
    }

    func readData(track: Int, to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        guard !suppressRead() else { return .nothingRead }
        maybeNotifyDownstreamFormat(track: track)

        let result = try! sampleQueues[track].read(
            buffer: buffer,
            readFlags: readFlags,
            loadingFinished: loadingFinished
        )

        if result == .nothingRead {
            maybeStartDeferredRetry(track: track)
        }

        return result
    }

    func skipData(track: Int, position time: CMTime) -> Int {
        guard !suppressRead() else { return .zero }

        maybeNotifyDownstreamFormat(track: track)
        let sampleQueue = sampleQueues[track]
        let skipCount = sampleQueue.getSkipCount(time: time, allowEndOfQueue: loadingFinished)
        sampleQueue.skip(count: skipCount)
        if skipCount == 0 {
            maybeStartDeferredRetry(track: track)
        }

        return skipCount
    }

    func installTrigger(track: Int, condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        sampleQueues[track].installTrigger(condition: condition, body)
    }

    func removeTrigger(track: Int, token: QueueTriggerToken) {
        sampleQueues[track].removeTrigger(token)
    }

    func testTrigger(track: Int, token: QueueTriggerToken) -> Bool {
        sampleQueues[track].testTrigger(token)
    }

    func maybeNotifyDownstreamFormat(track: Int) {
        
    }

    private func maybeStartDeferredRetry(track: Int) {
        assertPrepared()
        if !pendingDeferredRetry || haveAudioVideoTracks && !trackState.isAudioOrVideo[track] ||
            sampleQueues[track].isReady(loadingFinished: false) {
            return
        }

        pendingResetPosition = .zero
        pendingDeferredRetry = false
        notifyDiscontinuity = true
        lastSeekPosition = .zero
        extractedSamplesCountAtStartOfLoad = 0

        sampleQueues.forEach { $0.reset() }

        callback?.continueLoadingRequested(with: self)
    }

    private func suppressRead() -> Bool {
        return notifyDiscontinuity || isPendingReset()
    }

    func startLoading() {
        assert(queue.isCurrent())
        let loadable = ExtractingLoadable(
            url: url,
            syncActor: loaderSyncActor,
            dataSource: dataSource,
            progressiveMediaExtractor: progressiveMediaExtractor,
            extractorOutput: self,
            loadCondition: loadCondition,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes,
            requestContiniueLoading: { [weak self] in
                guard let self else { return }
                queue.async { self.callback?.continueLoadingRequested(with: self) }
            }
        )

        if isPrepared {
            guard let seekMap else { return }

            if duration.isValid, pendingResetPosition > duration {
                loadingFinished = true
                pendingResetPosition = .invalid
                return
            }

            let seekPoints = seekMap.getSeekPoints(for: pendingResetPosition)
            loadable.setLoadPosition(
                position: seekPoints.first.position,
                time: pendingResetPosition
            )
            sampleQueues.forEach { $0.setStartTime(pendingResetPosition) }
            pendingResetPosition = .invalid
        }

        extractedSamplesCountAtStartOfLoad = getExtractedSamplesCount()
        loader.startLoading(loadable: loadable, callback: self, defaultMinRetryCount: 3)
    }

    func configureRetry(loadable: ExtractingLoadable, currentExtractedSampleCount: Int) -> Bool {
        if isLengthKnown || (seekMap != nil && seekMap?.getDuration().isValid == true) {
            // We're playing an on-demand stream. Resume the current loadable, which will
            // request data starting from the point it left off.
            extractedSamplesCountAtStartOfLoad = currentExtractedSampleCount
            return true
        } else if isPrepared && !suppressRead() {
            pendingDeferredRetry = true
            return false
        } else {
            notifyDiscontinuity = isPrepared
            lastSeekPosition = .zero
            extractedSamplesCountAtStartOfLoad = 0
            sampleQueues.forEach { $0.reset() }
            loadable.setLoadPosition(position: 0, time: .zero)
            return true
        }
    }
}

extension ProgressiveMediaPeriod: Loader.Callback {
    func onLoadStarted(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64, retryCount: Int) {
    }

    func onLoadCompleted(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64) {
        assert(queue.isCurrent())
        if !duration.isValid, let seekMap {
            let largestQueuedTimestamp = getLargestQueuedTimestamp(includeDisabledTracks: false)
            duration = largestQueuedTimestamp == .negativeInfinity ? .zero : largestQueuedTimestamp + CMTime.from(microseconds: 10_000)
            listener?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: isLive)
        }
//        if !isPrepared {
//            print()
//        }
        loadingFinished = true
        callback?.continueLoadingRequested(with: self)
    }

    func onLoadCancelled(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64, released: Bool) {
        assert(queue.isCurrent())
        if !released {
            sampleQueues.forEach { $0.reset() }
            if enabledTrackCount > 0 { callback?.continueLoadingRequested(with: self) }
        }
    }

    func onLoadError(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64, error: Error, errorCount: Int) -> Loader.LoadErrorAction {
        let extractedSamplesCount = getExtractedSamplesCount()
        let madeProgress = extractedSamplesCount > extractedSamplesCountAtStartOfLoad
        let configureRetry = configureRetry(loadable: loadable, currentExtractedSampleCount: extractedSamplesCount)
        return configureRetry ? .createRetryAction(resetErrorCount: madeProgress, retryDelayMillis: 100) : .dontRetry
    }

    private func onLoaderReleased() {
        assert(queue.isCurrent())
        sampleQueues.forEach { $0.release() }
        progressiveMediaExtractor.release()
    }
}

extension ProgressiveMediaPeriod: ExtractorOutput {
    func track(for id: Int, trackType: TrackType) throws -> TrackOutput {
        queue.sync { prepareTrackOutput(id: id) }
    }

    func endTracks() {
        queue.async { [self] in
            sampleQueuesBuild = true
            maybeFinishPrepare()
        }
    }

    func seekMap(seekMap: SeekMap) {
        queue.async {
            self.setSeekMap(seekMap)
        }
    }
}

extension ProgressiveMediaPeriod: SampleQueueDelegate {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: Format) {
        maybeFinishPrepare()
    }
}

private extension ProgressiveMediaPeriod {
    private func prepareTrackOutput(id: Int) -> TrackOutput {
        assert(queue.isCurrent())
        for index in 0..<sampleQueues.count {
            if id == sampleQueueTrackIds[index] {
                return sampleQueues[index]
            }
        }

        let trackOutput = TriggerableSampleQueue(queue: queue, allocator: allocator)
        trackOutput.delegate = self
        sampleQueueTrackIds.append(id)
        sampleQueues.append(trackOutput)
        return trackOutput
    }

    func setSeekMap(_ seekMap: SeekMap) {
        assert(queue.isCurrent())
        duration = seekMap.getDuration()
        self.seekMap = seekMap
        if isPrepared {
            listener?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: false)
        } else {
            self.maybeFinishPrepare()
        }
    }

    func maybeFinishPrepare() {
        assert(queue.isCurrent())
        guard !didRelease, !isPrepared, sampleQueuesBuild, let seekMap else { return }

        for sampleQueue in sampleQueues {
            if sampleQueue.getUpstreamFormat() == nil {
                return
            }
        }
        loadCondition.close()
        let trackCount = sampleQueues.count
        var trackGroups: [TrackGroup] = []
        var isAudioOrVideo: [Bool] = []

        for index in 0..<trackCount {
            guard let format = sampleQueues[index].getUpstreamFormat() else {
                continue
            }

            do {
                try trackGroups.append(TrackGroup(id: String(index), formats: [format]))
                // TODO: real mime type
                let isAudioVideo = true //format.mediaType == .audio || format.mediaType == .video
                isAudioOrVideo.append(isAudioVideo)
                haveAudioVideoTracks = haveAudioVideoTracks || isAudioVideo
            } catch {
                continue
            }
        }

        trackState = TrackState(tracks: .init(trackGroups: trackGroups), isAudioOrVideo: isAudioOrVideo)
        listener?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: false)
        isPrepared = true
        callback?.didPrepare(mediaPeriod: self)
    }

    private func seekInsideBuffer(isAudioOrVideo: [Bool], position: CMTime, isSameAsLastSeekPosition: Bool) -> Bool {
        for (index, sampleQueue) in sampleQueues.enumerated() {
            if sampleQueue.getReadIndex() == 0 && isSameAsLastSeekPosition {
                continue
            }

            let seekInsideQueue = sampleQueue.seek(time: position, allowTimeBeyondBuffer: false)

            if !seekInsideQueue, (isAudioOrVideo[index] || !haveAudioVideoTracks) {
                return false
            }
        }

        return true
    }

    private func getExtractedSamplesCount() -> Int {
        sampleQueues.reduce(0, { $0 + $1.getWriteIndex() })
    }

    private func getLargestQueuedTimestamp(includeDisabledTracks: Bool) -> CMTime {
        var largestQueuedTimestamp = CMTime.negativeInfinity

        for (index, sampleQueue) in sampleQueues.enumerated() {
            if includeDisabledTracks || trackState.trackEnabledState[index] {
                largestQueuedTimestamp = max(largestQueuedTimestamp, sampleQueue.getLargestQueuedTimestamp())
            }
        }

        return largestQueuedTimestamp
    }

    private func isPendingReset() -> Bool {
        pendingResetPosition.isValid
    }

    private func assertPrepared() {
        assert(isPrepared)
        assert(!trackState.tracks.isEmpty)
        assert(seekMap != nil)
    }
}

private extension ProgressiveMediaPeriod {
    final class SampleStreamHolder: TriggerableSampleStream {
        let track: Int
        private let handlers: Handlers

        struct Handlers {
            let isReadyClosure: (Int) -> Bool
            let errorClosure: (Int) throws -> Void
            let readDataClosure: (Int, DecoderInputBuffer, ReadFlags) throws -> SampleStreamReadResult
            let skipDataClosure: (Int, CMTime) -> Int
            let installTrigger: (Int, TriggerCondition, ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken
            let removeTrigger: (Int, QueueTriggerToken) -> Void
            let testTrigger: (Int, QueueTriggerToken) -> Bool
        }

        init(
            track: Int,
            handlers: Handlers
        ) {
            self.track = track
            self.handlers = handlers
        }

        func isReady() -> Bool {
            handlers.isReadyClosure(track)
        }

        func maybeThrowError() throws {
            try handlers.errorClosure(track)
        }

        func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
            try handlers.readDataClosure(track, buffer, readFlags)
        }

        func skipData(position: CMTime) -> Int {
            handlers.skipDataClosure(track, position)
        }

        func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
            handlers.installTrigger(track, condition, body)
        }

        func removeTrigger(_ token: QueueTriggerToken) {
            handlers.removeTrigger(track, token)
        }

        func testTrigger(_ token: QueueTriggerToken) -> Bool {
            handlers.testTrigger(track, token)
        }
    }

    struct TrackState {
        let tracks: TrackGroupArray
        let isAudioOrVideo: [Bool]
        var trackEnabledState: [Bool]
        var trackNotifiedDownstreamFormats: [Bool]

        init(tracks: TrackGroupArray, isAudioOrVideo: [Bool]) {
            self.tracks = tracks
            self.isAudioOrVideo = isAudioOrVideo
            trackEnabledState = Array(repeating: false, count: tracks.count)
            trackNotifiedDownstreamFormats = Array(repeating: false, count: tracks.count)
        }

        static var empty: TrackState = .init(tracks: .empty, isAudioOrVideo: [])
    }
}

extension ProgressiveMediaPeriod {
    final class ExtractingLoadable: Loadable {
        private let url: URL
        private let syncActor: PlayerActor
        private let dataSource: DataSource
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
            dataSource: DataSource,
            progressiveMediaExtractor: ProgressiveMediaExtractor,
            extractorOutput: ExtractorOutput,
            loadCondition: AsyncConditionVariable,
            continueLoadingCheckIntervalBytes: Int,
            requestContiniueLoading: @escaping () -> Void
        ) {
            self.url = url
            self.syncActor = syncActor
            self.dataSource = dataSource
            self.progressiveMediaExtractor = progressiveMediaExtractor
            self.extractorOutput = extractorOutput
            self.loadCondition = loadCondition
            self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
            self.requestContiniueLoading = requestContiniueLoading
        }

        func load(isolation: isolated any Actor) async throws {
            syncActor.assertIsolated()
            var result: ExtractorReadResult = .continueRead

            while result == .continueRead, !Task.isCancelled {
                do {
                    let dataSpec = buildDataSpec(position: position)
                    let length = try await dataSource.open(dataSpec: dataSpec, isolation: isolation)
                    guard !Task.isCancelled else { throw CancellationError() }

                    try await progressiveMediaExtractor.prepare(
                        dataReader: dataSource,
                        url: url,
                        response: dataSource.urlResponse,
                        range: NSRange(location: position, length: length),
                        output: extractorOutput,
                        isolation: isolation
                    )

                    if pendingExtractorSeek {
                        try progressiveMediaExtractor.seek(
                            position: position,
                            time: seekTime,
                            isolation: isolation
                        )
                        pendingExtractorSeek = false
                    }

                    while result == .continueRead, !Task.isCancelled {
                        try await loadCondition.wait()
                        guard !Task.isCancelled else { throw CancellationError() }
                        result = try await progressiveMediaExtractor.read(isolation: isolation)
                        if let currentInputPosition = progressiveMediaExtractor.getCurrentInputPosition(isolation: isolation),
                           currentInputPosition > position + continueLoadingCheckIntervalBytes {
                            position = currentInputPosition
                            loadCondition.close()
                            requestContiniueLoading()
                        }
                    }
                } catch {
                    await postLoadTask(result: &result, isolation: isolation)
                    throw error
                }

                await postLoadTask(result: &result, isolation: isolation)
            }
        }

        func setLoadPosition(position: Int, time: CMTime) {
            self.position = position
            self.seekTime = time
            pendingExtractorSeek = true
        }

        private func postLoadTask(result: inout ExtractorReadResult, isolation: isolated any Actor) async {
            if case let .seek(offset) = result {
                position = offset
                result = .continueRead
            } else if let currentInputPosition = progressiveMediaExtractor.getCurrentInputPosition(isolation: isolation) {
                position = currentInputPosition
            }

            _ = try? await dataSource.close(isolation: isolation)
        }

        private func buildDataSpec(position: Int) -> DataSpec {
            return .spec(from: url, offset: position, length: 0)
        }
    }
}
