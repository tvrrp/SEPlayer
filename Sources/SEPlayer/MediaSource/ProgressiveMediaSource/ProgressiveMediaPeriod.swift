//
//  ProgressiveMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import Foundation

final class ProgressiveMediaPeriod: MediaPeriod {
    protocol Delegate: AnyObject {
        func sourceInfoRefreshed(duration: Int64, seekMap: SeekMap, isLive: Bool)
    }

    var trackGroups: [TrackGroup] { trackGroupState.tracks }
    var bufferedPosition: Int64 = .timeUnset
    var nextLoadPosition: Int64 = .timeUnset
    var isLoading: Bool { queue.sync { loader?.isLoading ?? false } }

    private let url: URL
    private let queue: Queue
    private let dataSource: DataSource
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let allocator: Allocator
    private let loadCondition: LoadConditionCheckable
    private let continueLoadingCheckIntervalBytes: Int
    weak var delegate: Delegate?
    weak var mediaSourceEventDelegate: MediaSourceEventListener?

    private var loader: ExtractingLoadable?

    private var callback: (any MediaPeriodCallback)?
    private typealias TrackId = Int
    
    private var duration: Int64 = .timeUnset

    private var sampleQueues: [(id: Int, queue: SampleQueue)] = []
    private var sampleQueuesBuild: Bool = false
    
    private var trackGroupState = TrackState.empty

    private var pendingResetTime: Int64?
    private var seekMap: SeekMap?

    private var isPrepared: Bool = false
    private var loadingFinished: Bool = false
    private var didRelease: Bool = false

    init(
        url: URL,
        queue: Queue,
        dataSource: DataSource,
        progressiveMediaExtractor: ProgressiveMediaExtractor,
        mediaSourceEventDelegate: MediaSourceEventListener,
        delegate: Delegate,
        allocator: Allocator,
        loadCondition: LoadConditionCheckable,
        continueLoadingCheckIntervalBytes: Int
    ) {
        self.url = url
        self.queue = queue
        self.dataSource = dataSource
        self.progressiveMediaExtractor = progressiveMediaExtractor
        self.mediaSourceEventDelegate = mediaSourceEventDelegate
        self.delegate = delegate
        self.allocator = allocator
        self.loadCondition = loadCondition
        self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
    }

    func release() {
        if isPrepared {
            sampleQueues.forEach { _, queue in
                queue.preRelease()
            }
        }

        loader?.cancelLoad()
        callback = nil
        didRelease = true
        if loader?.isLoading == false {
            onLoadCanceled()
        }
    }

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
        self.callback = callback
        startLoading()
    }

    func selectTrack(
        selections: [SETrackSelection?],
        streams: inout [SampleStream?],
        position: Int64
    ) -> Int64 {
        let tracks = trackGroupState.tracks

        for (index, selection) in selections.enumerated() {
            if let selection, streams[index] == nil {
                if let trackIndex = tracks.index(of: selection.trackGroup)  {
                    streams[index] = SampleStreamHolder(
                        track: trackIndex,
                        isReadyClosure: isReady,
                        readDataClosure: readData,
                        skipDataClosure: skipData,
                        returnToSyncSampleClosure: returnToSyncSample
                    )
                } else {
                    streams[index] = nil
                    continue
                }
            }
        }

        return position
    }

    func discardBuffer(to position: Int64, toKeyframe: Bool) {
        assert(isPrepared)
        // TODO: guard !isPendingReset() else { return }

        let trackEnabledStates = trackGroupState.trackEnabledState

        sampleQueues.enumerated().forEach { sequence in
            sequence.element.queue.discard(
                to: position, to: toKeyframe, stopAtReadPosition: trackEnabledStates[sequence.offset]
            )
        }
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
//        guard !loadingFinished, 
        return false
    }

    func seek(to position: Int64) {
        
    }

    func startLoading() {
        assert(queue.isCurrent())
        let delegate = mediaSourceEventDelegate
        let loader = ExtractingLoadable(
            url: url, queue: queue,
            dataSource: dataSource,
            progressiveMediaExtractor: progressiveMediaExtractor,
            extractorOutput: self,
            loadCondition: loadCondition,
            continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes
        )
        self.loader = loader

        loader.startLoading { [weak self] error in
            guard let self else {
                delegate?.loadCancelled(windowIndex: 0, mediaPeriodId: nil, loadEventInfo: Void(), mediaLoadData: Void())
                return
            }
            if let error {
                onLoadError(error: error)
            } else {
                onLoadCompleted()
            }
        }
    }

    func onLoadCompleted() {
        mediaSourceEventDelegate?.loadCompleted(
            windowIndex: 0, mediaPeriodId: nil, loadEventInfo: Void(), mediaLoadData: Void()
        )
        callback?.continueLoadingRequested(with: self)
    }

    func onLoadCanceled() {
        if didRelease {
            sampleQueues.forEach { _, queue in
                queue.release()
            }
            progressiveMediaExtractor.release()
        } else {
            mediaSourceEventDelegate?.loadCancelled(
                windowIndex: 0, mediaPeriodId: nil, loadEventInfo: Void(), mediaLoadData: Void()
            )
        }
    }

    func onLoadError(error: Error) {
        switch error {
        case is CancellationError:
            onLoadCanceled()
        default:
            mediaSourceEventDelegate?.loadError(
                windowIndex: 0, mediaPeriodId: nil, loadEventInfo: Void(), mediaLoadData: Void(), error: error, wasCancelled: false
            )
        }
    }
}

extension ProgressiveMediaPeriod: ExtractorOutput {
    func track(for id: Int, trackType: TrackType) -> TrackOutput {
        queue.sync {
            return prepareTrackOutput2(id: id)
        }
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

extension ProgressiveMediaPeriod {
    func isReady(track: Int) -> Bool {
        assert(queue.isCurrent())
        return !suppressRead() && sampleQueues.queue(for: track)?.isReady(loadingFinished: loadingFinished) == true
    }

    func readData(track: Int, to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
        guard let sampleStream = sampleQueues.queue(for: track) else {
            return .nothingRead
        }

        return try sampleStream.read(
            buffer: buffer,
            readFlags: readFlags,
            loadingFinished: loadingFinished
        )
    }

    func skipData(track: Int, position time: Int64) -> Int {
//        sampleQueues2[track]?.
        return 0
    }

    func returnToSyncSample(track: Int) -> Bool {
        guard let sampleStream = sampleQueues.queue(for: track) else {
            return false
        }
        let currentTime = sampleStream.getLargestReadTimestamp()
        return sampleStream.seek(to: currentTime, allowTimeBeyondBuffer: false)
    }
}

private extension ProgressiveMediaPeriod {
    private func prepareTrackOutput(id: TrackId) -> TrackOutput {
        assert(queue.isCurrent())
        for (sampleQueueId, sampleQueue) in sampleQueues {
            if sampleQueueId == id {
                return sampleQueue
            }
        }

        let trackOutput = SampleQueue(queue: queue, allocator: allocator)
        trackOutput.delegate = self
        sampleQueues.append((id, trackOutput))
        return trackOutput
    }

    func setSeekMap(_ seekMap: SeekMap) {
        assert(queue.isCurrent())
        duration = seekMap.getDuration()
        self.seekMap = seekMap
        if isPrepared {
            delegate?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: false)
        } else {
            self.maybeFinishPrepare()
        }
    }

    func suppressRead() -> Bool {
        return pendingResetTime != nil
    }
}

extension ProgressiveMediaPeriod: SampleQueueDelegate {
    func sampleQueue(_ sampleQueue: SampleQueue, didChange format: CMFormatDescription) {
        
    }
}

private extension ProgressiveMediaPeriod {
    func maybeFinishPrepare() {
        guard !didRelease, !isPrepared, sampleQueuesBuild, let seekMap else { return }

        var trackGroups: [TrackGroup] = []
        var isAudioOrVideo: [Bool] = []
        for (id, sampleQueue) in sampleQueues {
            guard let format = sampleQueue.getUpstreamFormat() else {
                return
            }

            do {
                try trackGroups.append(TrackGroup(id: String(id), formats: [format]))
                isAudioOrVideo.append(format.mediaType == .audio || format.mediaType == .video)
            } catch {
                continue
            }
        }

        trackGroupState = TrackState(
            tracks: trackGroups,
            isAudioOrVideo: isAudioOrVideo,
            trackEnabledState: []
        )
        delegate?.sourceInfoRefreshed(duration: duration, seekMap: seekMap, isLive: false)
        isPrepared = true
        callback?.didPrepare(mediaPeriod: self)
    }
}

private extension ProgressiveMediaPeriod {
    struct SampleStreamHolder: SampleStream {
        let track: Int
        let isReadyClosure: ((_ track: Int) -> Bool)
        let readDataClosure: ((_ track: Int, _ buffer: DecoderInputBuffer, _ readFlags: ReadFlags) throws -> SampleStreamReadResult)
        let skipDataClosure: ((_ track: Int, _ time: Int64) -> Int)
        let returnToSyncSampleClosure: ((_ track: Int) -> Bool)

        func isReady() -> Bool {
            isReadyClosure(track)
        }

        func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult {
            try readDataClosure(track, buffer, readFlags)
        }

        func skipData(position time: Int64) -> Int {
            skipDataClosure(track, time)
        }

        func returnToSyncSample() -> Bool {
            returnToSyncSampleClosure(track)
        }
    }

    struct TrackState {
        let tracks: [TrackGroup]
        let isAudioOrVideo: [Bool]
        let trackEnabledState: [Bool]

        static var empty: TrackState = .init(tracks: [], isAudioOrVideo: [], trackEnabledState: [])
    }
}

private extension ProgressiveMediaPeriod {
    final class ExtractingLoadable {
        var isLoading: Bool {
            queue.sync { !isCancelled && didFinish }
        }

        private let url: URL
        private let queue: Queue
        private let dataSource: DataSource
        private let progressiveMediaExtractor: ProgressiveMediaExtractor
        private let extractorOutput: ExtractorOutput
        private let loadCondition: LoadConditionCheckable
        private let continueLoadingCheckIntervalBytes: Int
        private var position: Int = 0

        private var seekTime: Int64?
        private var didFinish: Bool = false
        private var isCancelled: Bool = false

        init(
            url: URL,
            queue: Queue,
            dataSource: DataSource,
            progressiveMediaExtractor: ProgressiveMediaExtractor,
            extractorOutput: ExtractorOutput,
            loadCondition: LoadConditionCheckable,
            continueLoadingCheckIntervalBytes: Int
        ) {
            self.url = url
            self.queue = queue
            self.dataSource = dataSource
            self.progressiveMediaExtractor = progressiveMediaExtractor
            self.extractorOutput = extractorOutput
            self.loadCondition = loadCondition
            self.continueLoadingCheckIntervalBytes = continueLoadingCheckIntervalBytes
        }

        func cancelLoad() {
            queue.async {
                self.isCancelled = true
            }
        }

        func startLoading(completion: @escaping (Error?) -> Void) {
            assert(queue.isCurrent())
            dataSource.close()
            guard !isCancelled else {
                didFinish = true
                return completion(CancellationError())
            }

            let dataSpec = buildDataSpec(position: position)
            dataSource.open(dataSpec: dataSpec, completionQueue: queue) { [weak self] result in
                guard let self else { return }
                do {
                    assert(queue.isCurrent())
                    switch result {
                    case let .success(lenght):
                        try progressiveMediaExtractor.prepare(
                            dataReader: dataSource,
                            url: url,
                            response: dataSource.urlResponce,
                            range: NSRange(location: position, length: lenght),
                            output: extractorOutput
                        )
                        if let seekTime {
                            progressiveMediaExtractor.seek(position: position, time: seekTime)
                            self.seekTime = nil
                        }
                        startLoad { loadResult in
                            switch loadResult {
                            case .continueRead:
                                if let readPosition = self.progressiveMediaExtractor.getCurrentInputPosition() {
                                    self.position = readPosition
                                    self.startLoading(completion: completion)
                                }
                            case let .seek(offset):
                                self.position = offset
                                self.startLoading(completion: completion)
                            case .endOfInput:
                                self.didFinish = true
                                completion(nil)
                            case let .error(error):
                                self.didFinish = true
                                completion(error)
                            }
                        }
                    case let .failure(error):
                        throw error
                    }
                } catch {
                    didFinish = true
                    completion(error)
                }
            }
        }

        func setLoadPosition(position: Int, time: Int64) {
            assert(queue.isCurrent())
            self.position = position
            self.seekTime = time
        }

        private func startLoad(loadCompletion: @escaping (ExtractorReadResult) -> Void) {
            assert(queue.isCurrent())
            readFromExtractor(extractor: progressiveMediaExtractor) { [weak self] result in
                guard let self else { return false }
                assert(queue.isCurrent())
                if result == .continueRead {
                    if let currentInputPosition = progressiveMediaExtractor.getCurrentInputPosition(),
                       currentInputPosition > position + continueLoadingCheckIntervalBytes {
                        position = currentInputPosition
                        let condition = loadCondition.checkLoadingCondition() && !isCancelled
                        if !condition { loadCompletion(.error(CancellationError())) }
                        return condition
                    }
                    return !isCancelled
                }
                loadCompletion(result)
                return false
            }
        }

        private func readFromExtractor(extractor: ProgressiveMediaExtractor, completion: @escaping (ExtractorReadResult) -> Bool) {
            extractor.read { [weak self] result in
                guard let self else { return }
                assert(queue.isCurrent())
                if completion(result) {
                    readFromExtractor(extractor: extractor, completion: completion)
                }
            }
        }

        private func buildDataSpec(position: Int) -> DataSpec {
            return .spec(from: url, offset: position, length: 0)
        }
    }
}

private extension Array where Element == (id: Int, queue: SampleQueue) {
    func queue(for id: Int) -> SampleQueue? {
        first(where: { $0.0 == id })?.1
    }
}
