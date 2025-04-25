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
        func sourceInfoRefreshed(duration: CMTime)
    }

    var trackGroups: [TrackGroup] { trackGroupState.tracks }
    var bufferedPosition: CMTime = .invalid
    var nextLoadPosition: CMTime = .invalid
    var isLoading: Bool { queue.sync { loader?.isLoading ?? false } }

    private let url: URL
    private let queue: Queue
    private let dataSource: DataSource
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
//    private let allocator: Allocator
    private let allocator: Allocator2
    private let loadCondition: LoadConditionCheckable
    private let continueLoadingCheckIntervalBytes: Int
    weak var delegate: Delegate?
    weak var mediaSourceEventDelegate: MediaSourceEventListener?

    private var loader: ExtractingLoadable?

    private var callback: (any MediaPeriodCallback)?
    private typealias TrackId = Int
    
    private var duration: CMTime = .indefinite

    private var sampleQueues: [TrackId: SampleQueue] = [:]
    private var sampleQueues2: [(id: Int, queue: SampleQueue2)] = []
    private var sampleQueuesBuild: Bool = false
    
    private var trackGroupState = TrackState.empty

    private var pendingResetTime: CMTime?
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
//        allocator: Allocator,
        allocator: Allocator2,
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

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        self.callback = callback
        startLoading()
    }

    func continueLoading(with loadingInfo: Void) -> Bool {
        return false
    }

    func discardBuffer(to position: Int64, toKeyframe: Bool) {
        assert(isPrepared)
        for sampleQueue in sampleQueues.values {
            sampleQueue.discardTo(position: position, toKeyframe: toKeyframe)
        }
    }

    func seek(to position: Int64) {
        
    }

    func selectTrack(
        selections: [SETrackSelection?],
        streams: inout [SampleStream2?],
        position: Int64
    ) -> Int64 {
        let tracks = trackGroupState.tracks

        for (index, selection) in selections.enumerated() {
            if let selection, streams[index] == nil {
                if let trackIndex = tracks.index(of: selection.trackGroup)  {
                    streams[index] = SampleStreamHolder2(
                        track: trackIndex,
                        isReadyClosure: isReady2,
                        readDataClosure: readData2,
                        skipDataClosure: skipData2
                    )
                } else {
                    streams[index] = nil
                    continue
                }
            }
        }

        return 0
//        return selections.compactMap { selection in
//            guard let trackIndex = trackGroupState.firstIndex(where: { $0.trackGroup == selection.trackGroup }) else {
//                return nil
//            }
//            return SampleStreamHolder(
//                format: selection.selectedFormat,
//                track: trackIndex,
//                isReadyClosure: { [weak self] track in
//                    self?.isReady(track: track) ?? false
//                }, readDataClosure: { [weak self] track, decoderInput in
//                    return try self?.readData(track: track, to: decoderInput) ?? .nothingRead
//                }, readDataClosure2: { [weak self] track, decoderInput, flags in
//                    return try self?.readData(track: track, to: decoderInput, flags: flags) ?? .nothingRead
//                }, skipDataClosure: { [weak self] track, time in
//                    self?.skipData(track: track, to: time) ?? 0
//                })
//        }
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
        mediaSourceEventDelegate?.loadCancelled(
            windowIndex: 0, mediaPeriodId: nil, loadEventInfo: Void(), mediaLoadData: Void()
        )
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

    func release() {
        
    }
}

extension ProgressiveMediaPeriod: ExtractorOutput {
//    func track(for id: Int, trackType: TrackType, format: CMFormatDescription) -> TrackOutput {
//        queue.sync {
//            return prepareTrackOutput(id: id, format: format)
//        }
//    }
    func track(for id: Int, trackType: TrackType) -> TrackOutput2 {
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
        return !suppressRead() && sampleQueues[track]?.isReady(didFinish: loadingFinished) == true
    }

    func readData(track: Int, to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
        assert(queue.isCurrent())
        guard !suppressRead(), let sampleQueue = sampleQueues[track] else { return .nothingRead }
        
        let result = try sampleQueue.readData(to: decoderInput, loadingFinished: loadingFinished)

        if result == .nothingRead {
            // TODO: maybeStartDeferredRetry
        }
        return result
    }

    func readData(track: Int, to decoderInput: CMBlockBuffer, flags: ReadFlags) throws -> SampleStreamReadResult {
        assert(queue.isCurrent())
        guard !suppressRead(), let sampleQueue = sampleQueues[track] else { return .nothingRead }

        let result = try sampleQueue.readData(to: decoderInput, flags: flags, loadingFinished: loadingFinished)

        if result == .nothingRead {
            // TODO: maybeStartDeferredRetry
        }
        return result
    }

    func skipData(track: Int, to time: Int64) -> Int {
        assert(queue.isCurrent())
        guard !suppressRead(), let sampleQueue = sampleQueues[track] else { return 0 }
        let skipCount = sampleQueue.skipCount(for: time, allowEndOfQueue: loadingFinished)
        sampleQueue.skip(count: skipCount)
        if skipCount == 0 {
            // TODO: maybeStartDeferredRetry
        }
        return skipCount
    }
}

extension ProgressiveMediaPeriod {
    func isReady2(track: Int) -> Bool {
        assert(queue.isCurrent())
        return !suppressRead() && sampleQueues2.queue(for: track)?.isReady(loadingFinished: loadingFinished) == true
    }

    func readData2(track: Int, to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult2 {
        guard let sampleStream = sampleQueues2.queue(for: track) else {
            return .nothingRead
        }

        return try sampleStream.read(
            buffer: buffer,
            readFlags: readFlags,
            loadingFinished: loadingFinished
        )
    }

    func skipData2(track: Int, position time: Int64) -> Int {
//        sampleQueues2[track]?.
        return 0
    }
}

private extension ProgressiveMediaPeriod {
//    private func prepareTrackOutput(id: TrackId, format: CMFormatDescription) -> TrackOutput {
//        assert(queue.isCurrent())
//        if let trackOutput = sampleQueues[id] {
//            return trackOutput
//        }
//
//        let queue = SampleQueue(queue: queue, allocator: allocator, format: format)
//        sampleQueues[id] = queue
//        return queue
//    }
    private func prepareTrackOutput2(id: TrackId) -> TrackOutput2 {
        assert(queue.isCurrent())
        for (sampleQueueId, sampleQueue) in sampleQueues2 {
            if sampleQueueId == id {
                return sampleQueue
            }
        }

        let trackOutput = SampleQueue2(queue: queue, allocator: allocator)
        trackOutput.delegate = self
        sampleQueues2.append((id, trackOutput))
        return trackOutput
    }

    func setSeekMap(_ seekMap: SeekMap) {
        assert(queue.isCurrent())
        duration = seekMap.getDuration()
        self.seekMap = seekMap
        if isPrepared {
            delegate?.sourceInfoRefreshed(duration: duration)
        } else {
            self.maybeFinishPrepare()
        }
    }

    func suppressRead() -> Bool {
        return pendingResetTime != nil
    }
}

extension ProgressiveMediaPeriod: SampleQueueDelegate {
    func sampleQueue(_ sampleQueue: SampleQueue2, didChange format: CMFormatDescription) {
        
    }
}

private extension ProgressiveMediaPeriod {
    func maybeFinishPrepare() {
        guard !didRelease, !isPrepared, sampleQueuesBuild, seekMap != nil else { return }

        var trackGroups: [TrackGroup] = []
        var isAudioOrVideo: [Bool] = []
        for (id, sampleQueue) in sampleQueues2 {
            guard let format = sampleQueue.getUpstreamFormat() else {
                return
            }

            do {
                try? trackGroups.append(TrackGroup(id: String(id), formats: [format]))
                isAudioOrVideo.append(format.mediaType == .audio || format.mediaType == .video)
            } catch {
                continue
            }
        }

        trackGroupState = TrackState(tracks: trackGroups, isAudioOrVideo: isAudioOrVideo)
        delegate?.sourceInfoRefreshed(duration: duration)
        isPrepared = true
        callback?.didPrepare(mediaPeriod: self)
    }
}

private extension ProgressiveMediaPeriod {
    struct SampleStreamHolder: SampleStream {
        let format: CMFormatDescription
        let track: Int
        let isReadyClosure: ((_ track: Int) -> Bool)
        let readDataClosure: ((_ track: Int, _ decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult)
        let readDataClosure2: ((_ track: Int, _ decoderInput: CMBlockBuffer, _ flags: ReadFlags) throws -> SampleStreamReadResult)
        let skipDataClosure: ((_ track: Int, _ time: Int64) -> Int )

        func isReady() -> Bool {
            isReadyClosure(track)
        }

        func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
            return try readDataClosure(track, decoderInput)
        }

        func readData(to decoderInput: CMBlockBuffer, flags: ReadFlags) throws -> SampleStreamReadResult {
            return try readDataClosure2(track, decoderInput, flags)
        }

        func skipData(to time: Int64) -> Int {
            skipDataClosure(track, time)
        }
    }

    struct SampleStreamHolder2: SampleStream2 {
        let track: Int
        let isReadyClosure: ((_ track: Int) -> Bool)
        let readDataClosure: ((_ track: Int, _ buffer: DecoderInputBuffer, _ readFlags: ReadFlags) throws -> SampleStreamReadResult2)
        let skipDataClosure: ((_ track: Int, _ time: Int64) -> Int )

        func isReady() -> Bool {
            isReadyClosure(track)
        }

        func readData(to buffer: DecoderInputBuffer, readFlags: ReadFlags) throws -> SampleStreamReadResult2 {
            try readDataClosure(track, buffer, readFlags)
        }

        func skipData(position time: Int64) -> Int {
            skipDataClosure(track, time)
        }
    }

    struct TrackState {
        let tracks: [TrackGroup]
        let isAudioOrVideo: [Bool]

        static var empty: TrackState = .init(tracks: [], isAudioOrVideo: [])
    }
}

private extension ProgressiveMediaPeriod {
    final class ExtractingLoadable {
        var isLoading: Bool { !isCancelled }

        private let url: URL
        private let queue: Queue
        private let dataSource: DataSource
        private let progressiveMediaExtractor: ProgressiveMediaExtractor
        private let extractorOutput: ExtractorOutput
        private let loadCondition: LoadConditionCheckable
        private let continueLoadingCheckIntervalBytes: Int
        private var position: Int = 0

        private var seekTime: CMTime?
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
            guard !isCancelled else { return completion(CancellationError()) }
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
                                completion(nil)
                            case let .error(error):
                                completion(error)
                            }
                        }
                    case let .failure(error):
                        throw error
                    }
                } catch {
                    completion(error)
                }
            }
        }

        func setLoadPosition(position: Int, time: CMTime) {
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

private extension Array where Element == (id: Int, queue: SampleQueue2) {
    func queue(for id: Int) -> SampleQueue2? {
        first(where: { $0.0 == id })?.1
    }
}
