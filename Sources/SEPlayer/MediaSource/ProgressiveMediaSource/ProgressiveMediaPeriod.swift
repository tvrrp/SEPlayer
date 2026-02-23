//
//  ProgressiveMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

final class ProgressiveMediaPeriod: MediaPeriod {
    protocol Listener: AnyObject {
        func sourceInfoRefreshed(durationUs: Int64, seekMap: SeekMap, isLive: Bool)
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
    private var sampleQueues: [SampleQueue] = []
    private var sampleQueueTrackIds: [Int] = []
    private var sampleQueuesBuild: Bool = false

    private var isPrepared: Bool = false
    private var haveAudioVideoTracks: Bool = false
    private var isSingleSample: Bool = false
    private var trackState = TrackState.empty
    private weak var seekMap: SeekMap?
    private var durationUs: Int64 = .zero
    private var isLive: Bool = false

    private var seenFirstTrackSelection: Bool = false
    private var notifyDiscontinuity: Bool = false
    private var pendingInitialDiscontinuity: Bool = false
    private var enabledTrackCount = 0
    private var isLengthKnown: Bool = true

    private var lastSeekPositionUs: Int64 = .zero
    private var pendingResetPositionUs: Int64 = .timeUnset
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

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
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
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        positionUs: Int64
    ) -> Int64 {
        assertPrepared()
        var positionUs = positionUs
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

        var seekRequired = seenFirstTrackSelection ? oldEnabledTrackCount == 0 : positionUs != 0

        for (index, selection) in selections.enumerated() {
            if let selection, streams[index] == nil {
                if let trackIndex = tracks.firstIndex(of: selection.trackGroup)  {
                    streams[index] = SampleStreamHolder(
                        track: trackIndex,
                        isReadyClosure: isReady,
                        errorClosure: maybeThrowError,
                        readDataClosure: readData,
                        skipDataClosure: skipData
                    )
                    enabledTrackCount += 1
                    trackEnabledStates[index] = true
                    streamResetFlags[index] = true

                    if !seekRequired {
                        let sampleQueue = sampleQueues[index]
                        seekRequired = sampleQueue.getReadIndex() != 0
                            && !sampleQueue.seek(to: positionUs, allowTimeBeyondBuffer: true)
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
            positionUs = seek(to: positionUs)
            for index in 0..<streams.count {
                if streams[index] != nil { streamResetFlags[index] = true }
            }
        }

        trackState.trackEnabledState = trackEnabledStates
        seenFirstTrackSelection = true
        return positionUs
    }

    func discardBuffer(to position: Int64, toKeyframe: Bool) {
        assertPrepared()
        guard !isPendingReset() else { return }

        let trackEnabledStates = trackState.trackEnabledState

        for (index, sampleQueue) in sampleQueues.enumerated() {
            sampleQueue.discard(to: position, to: toKeyframe, stopAtReadPosition: trackEnabledStates[index])
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

    func getNextLoadPositionUs() -> Int64 {
        getBufferedPositionUs()
    }

    func readDiscontinuity() -> Int64 {
        if pendingInitialDiscontinuity {
            pendingInitialDiscontinuity = false
            return lastSeekPositionUs
        }

        if notifyDiscontinuity,
           (loadingFinished || getExtractedSamplesCount() > extractedSamplesCountAtStartOfLoad) {
            notifyDiscontinuity = false
            return lastSeekPositionUs
        }

        return .timeUnset
    }

    func getBufferedPositionUs() -> Int64 {
        assertPrepared()
        if loadingFinished || enabledTrackCount == 0 {
            return .endOfSource
        } else if isPendingReset() {
            return pendingResetPositionUs
        }

        var largestQueuedTimestampUs = Int64.max
        if haveAudioVideoTracks {
            for (index, sampleQueue) in sampleQueues.enumerated() {
                if trackState.isAudioOrVideo[index],
                   trackState.trackEnabledState[index],
                   !sampleQueue.lastSampleQueued() {
                    largestQueuedTimestampUs = min(largestQueuedTimestampUs, sampleQueue.getLargestQueuedTimestamp())
                }
            }
        }

        if largestQueuedTimestampUs == .max {
            largestQueuedTimestampUs = getLargestQueuedTimestampUs(includeDisabledTracks: false)
        }

        return largestQueuedTimestampUs == .min ? lastSeekPositionUs : largestQueuedTimestampUs
    }

    func seek(to position: Int64) -> Int64 {
        assertPrepared()
        guard let seekMap else { return .zero }
        let trackIsAudioVideoFlags = trackState.isAudioOrVideo
        let positionUs = seekMap.isSeekable() ? position : .zero

        notifyDiscontinuity = false
        let isSameAsLastSeekPosition = lastSeekPositionUs == positionUs
        lastSeekPositionUs = positionUs
        if isPendingReset() {
            pendingResetPositionUs = positionUs
            return positionUs
        }

        print("🥵 seek(to position = \(positionUs)")
        if (loadingFinished || loader.isLoading())
           && seekInsideBufferUs(isAudioOrVideo: trackIsAudioVideoFlags,
                                 positionUs: position,
                                 isSameAsLastSeekPosition: isSameAsLastSeekPosition) {
            return positionUs
        }

        pendingDeferredRetry = false
        pendingResetPositionUs = positionUs
        loadingFinished = false
        pendingInitialDiscontinuity = false

        if loader.isLoading() {
            sampleQueues.forEach { $0.discardToEnd() }
            loader.cancelLoading()
        } else {
            sampleQueues.forEach { $0.reset() }
        }

        return positionUs
    }

    func getAdjustedSeekPositionUs(positionUs: Int64, seekParameters: SeekParameters) -> Int64 {
        assertPrepared()
        guard let seekMap, seekMap.isSeekable() else {
            return .zero
        }

        let seekPoints = seekMap.getSeekPoints(for: positionUs)
        let position = seekParameters.resolveSyncPosition(
            positionUs: positionUs,
            firstSyncUs: seekPoints.first.timeUs,
            secondSyncUs: seekPoints.second.timeUs
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

    func skipData(track: Int, position time: Int64) -> Int {
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

    func maybeNotifyDownstreamFormat(track: Int) {
        
    }

    private func maybeStartDeferredRetry(track: Int) {
        assertPrepared()
        if !pendingDeferredRetry || haveAudioVideoTracks && !trackState.isAudioOrVideo[track] ||
            sampleQueues[track].isReady(loadingFinished: false) {
            return
        }

        pendingResetPositionUs = .zero
        pendingDeferredRetry = false
        notifyDiscontinuity = true
        lastSeekPositionUs = 0
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

            if durationUs != .timeUnset, pendingResetPositionUs > durationUs {
                loadingFinished = true
                pendingResetPositionUs = .timeUnset
                return
            }

            let seekPoints = seekMap.getSeekPoints(for: pendingResetPositionUs)
            loadable.setLoadPosition(
                position: seekPoints.first.position,
                time: pendingResetPositionUs
            )
            sampleQueues.forEach { $0.setStartTime(pendingResetPositionUs) }
            pendingResetPositionUs = .timeUnset
        }

        extractedSamplesCountAtStartOfLoad = getExtractedSamplesCount()
        loader.startLoading(loadable: loadable, callback: self, defaultMinRetryCount: 3)
    }

    func configureRetry(loadable: ExtractingLoadable, currentExtractedSampleCount: Int) -> Bool {
        if isLengthKnown || (seekMap != nil && seekMap?.getDurationUs() != .timeUnset) {
            // We're playing an on-demand stream. Resume the current loadable, which will
            // request data starting from the point it left off.
            extractedSamplesCountAtStartOfLoad = currentExtractedSampleCount
            return true
        } else if isPrepared && !suppressRead() {
            pendingDeferredRetry = true
            return false
        } else {
            notifyDiscontinuity = isPrepared
            lastSeekPositionUs = 0
            extractedSamplesCountAtStartOfLoad = 0
            sampleQueues.forEach { $0.reset() }
            loadable.setLoadPosition(position: 0, time: 0)
            return true
        }
    }
}

extension ProgressiveMediaPeriod: Loader.Callback {
    func onLoadStarted(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64, retryCount: Int) {
    }

    func onLoadCompleted(loadable: ExtractingLoadable, onTime: Int64, loadDurationMs: Int64) {
        assert(queue.isCurrent())
        if durationUs == .timeUnset, let seekMap {
            let largestQueuedTimestampUs = getLargestQueuedTimestampUs(includeDisabledTracks: false)
            durationUs = largestQueuedTimestampUs == .min ? .zero : largestQueuedTimestampUs + 10_000
            listener?.sourceInfoRefreshed(durationUs: durationUs, seekMap: seekMap, isLive: isLive)
        }
        if !isPrepared {
            print()
        }
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
    func track(for id: Int, trackType: TrackType) -> TrackOutput {
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

        let trackOutput = SampleQueue(queue: queue, allocator: allocator)
        trackOutput.delegate = self
        sampleQueueTrackIds.append(id)
        sampleQueues.append(trackOutput)
        return trackOutput
    }

    func setSeekMap(_ seekMap: SeekMap) {
        assert(queue.isCurrent())
        durationUs = seekMap.getDurationUs()
        self.seekMap = seekMap
        if isPrepared {
            listener?.sourceInfoRefreshed(durationUs: durationUs, seekMap: seekMap, isLive: false)
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
        listener?.sourceInfoRefreshed(durationUs: durationUs, seekMap: seekMap, isLive: false)
        isPrepared = true
        callback?.didPrepare(mediaPeriod: self)
    }

    private func seekInsideBufferUs(isAudioOrVideo: [Bool], positionUs: Int64, isSameAsLastSeekPosition: Bool) -> Bool {
        for (index, sampleQueue) in sampleQueues.enumerated() {
            if sampleQueue.getReadIndex() == 0 && isSameAsLastSeekPosition {
                continue
            }

            let seekInsideQueue = sampleQueue.seek(to: positionUs, allowTimeBeyondBuffer: false)

            if !seekInsideQueue, (isAudioOrVideo[index] || !haveAudioVideoTracks) {
                return false
            }
        }

        return true
    }

    private func getExtractedSamplesCount() -> Int {
        sampleQueues.reduce(0, { $0 + $1.getWriteIndex() })
    }

    private func getLargestQueuedTimestampUs(includeDisabledTracks: Bool) -> Int64 {
        var largestQueuedTimestampUs = Int64.min

        for (index, sampleQueue) in sampleQueues.enumerated() {
            if includeDisabledTracks || trackState.trackEnabledState[index] {
                largestQueuedTimestampUs = max(largestQueuedTimestampUs, sampleQueue.getLargestQueuedTimestamp())
            }
        }

        return largestQueuedTimestampUs
    }

    private func isPendingReset() -> Bool {
        pendingResetPositionUs != .timeUnset
    }

    private func assertPrepared() {
        assert(isPrepared)
        assert(!trackState.tracks.isEmpty)
        assert(seekMap != nil)
    }
}

private extension ProgressiveMediaPeriod {
    final class SampleStreamHolder: SampleStream {
        let track: Int
        let isReadyClosure: ((Int) -> Bool)
        let errorClosure: ((Int) throws -> Void)
        let readDataClosure: ((Int, DecoderInputBuffer, ReadFlags) throws -> SampleStreamReadResult)
        let skipDataClosure: ((Int, Int64) -> Int)

        init(
            track: Int,
            isReadyClosure: @escaping (Int) -> Bool,
            errorClosure: @escaping (Int) throws -> Void,
            readDataClosure: @escaping (Int, DecoderInputBuffer, ReadFlags) throws -> SampleStreamReadResult,
            skipDataClosure: @escaping (Int, Int64) -> Int
        ) {
            self.track = track
            self.isReadyClosure = isReadyClosure
            self.errorClosure = errorClosure
            self.readDataClosure = readDataClosure
            self.skipDataClosure = skipDataClosure
        }

        func isReady() -> Bool {
            isReadyClosure(track)
        }

        func maybeThrowError() throws {
            try errorClosure(track)
        }

        func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
            try readDataClosure(track, buffer, readFlags)
        }

        func skipData(position time: Int64) -> Int {
            skipDataClosure(track, time)
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
        private var seekTime: Int64 = .zero
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
                        progressiveMediaExtractor.seek(
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

        func setLoadPosition(position: Int, time: Int64) {
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

            await dataSource.close(isolation: isolation)
        }

        private func buildDataSpec(position: Int) -> DataSpec {
            return .spec(from: url, offset: position, length: 0)
        }
    }
}
