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

    var bufferedPosition: CMTime = .invalid
    var nextLoadPosition: CMTime = .invalid
    var isLoading: Bool { queue.sync { loader.isLoading } }
    var trackGroups: [TrackGroup] {
        assert(queue.isCurrent()); return trackGroupState.map { $0.trackGroup }
    }

    private let url: URL
    private let queue: Queue
    private let dataSource: DataSource
    private let progressiveMediaExtractor: ProgressiveMediaExtractor
    private let allocator: Allocator
    private let loadCondition: LoadConditionCheckable
    private let continueLoadingCheckIntervalBytes: Int
    weak var delegate: Delegate?
    weak var mediaSourceEventDelegate: MediaSourceEventListener?

    private lazy var loader: ExtractingLoadable = {
        ExtractingLoadable(
            url: url, queue: queue, dataSource: dataSource, progressiveMediaExtractor: progressiveMediaExtractor, extractorOutput: self, loadCondition: loadCondition, continueLoadingCheckIntervalBytes: continueLoadingCheckIntervalBytes
        )
    }()

    private var callback: (any MediaPeriodCallback)?
    private typealias TrackId = Int
    
    private var duration: CMTime = .indefinite

    private var sampleQueues: [TrackId: SampleQueue] = [:]
    private var sampleQueuesBuild: Bool = false
    
    private var trackGroupState: [TrackState] = []

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

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        self.callback = callback
        startLoading()
    }

    func continueLoading(with loadingInfo: Void) -> Bool {
        return false
    }

    func reevaluateBuffer(position: CMTime) { return }

    func discardBuffer(to time: CMTime, toKeyframe: Bool) {
        
    }

    func seek(to time: CMTime) {
        
    }

    func selectTrack(
        selections: [any SETrackSelection],
        on time: CMTime,
        delegate: SampleQueueDelegate
    ) -> [SampleStream] {
        return selections.compactMap { selection in
            guard let trackIndex = trackGroupState.firstIndex(where: { $0.trackGroup == selection.trackGroup }) else {
                return nil
            }
            sampleQueues[trackIndex]?.delegate = delegate
            return SampleStreamHolder(
                format: selection.selectedFormat,
                track: trackIndex,
                isReadyClosure: { [weak self] track in
                    self?.isReady(track: track) ?? false
                }, readDataClosure: { [weak self] track, decoderInput in
                    return try self?.readData(track: track, to: decoderInput) ?? .nothingRead
                }, skipDataClosure: { [weak self] track, time in
                    self?.skipData(track: track, to: time) ?? 0
                })
        }
    }

    func startLoading() {
        assert(queue.isCurrent())
        let delegate = mediaSourceEventDelegate
        self.loader.startLoading { [weak self] error in
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
    func track(for id: Int, trackType: TrackType, format: CMFormatDescription) -> TrackOutput {
        queue.sync {
            return prepareTrackOutput(id: id, format: format)
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
        
        let result = try sampleQueue.readData(to: decoderInput)

        if result == .nothingRead {
            // TODO: maybeStartDeferredRetry
        }
        return result
    }

    func skipData(track: Int, to time: CMTime) -> Int {
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

private extension ProgressiveMediaPeriod {
    private func prepareTrackOutput(id: TrackId, format: CMFormatDescription) -> TrackOutput {
        assert(queue.isCurrent())
        if let trackOutput = sampleQueues[id] {
            return trackOutput
        }

        let queue = SampleQueue(queue: queue, allocator: allocator, format: format)
        sampleQueues[id] = queue
        return queue
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

private extension ProgressiveMediaPeriod {
    func maybeFinishPrepare() {
        guard !didRelease, !isPrepared, sampleQueuesBuild, seekMap != nil else { return }

        do {
            let sampleQueues = sampleQueues.map { ($0.key, $0.value) }.sorted(by: { $0.0 < $1.0 }).map { $0.1 }
            trackGroupState = try sampleQueues.map { sampleQueue in
                let trackGroup = try TrackGroup(formats: [sampleQueue.format])
                return TrackState(
                    trackGroup: trackGroup,
                    isAudioOrVideo: trackGroup.type == .video || trackGroup.type == .audio
                )
            }

            delegate?.sourceInfoRefreshed(duration: duration)
            isPrepared = true
            callback?.didPrepare(mediaPeriod: self)
        } catch {
            
        }
    }
}

private extension ProgressiveMediaPeriod {
    struct SampleStreamHolder: SampleStream {
        let format: CMFormatDescription
        let track: Int
        let isReadyClosure: ((_ track: Int) -> Bool)
        let readDataClosure: ((_ track: Int, _ decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult)
        let skipDataClosure: ((_ track: Int, _ time: CMTime) -> Int )

        func isReady() -> Bool {
            isReadyClosure(track)
        }

        func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
            return try readDataClosure(track, decoderInput)
        }

        func skipData(to time: CMTime) -> Int {
            skipDataClosure(track, time)
        }
    }

    struct TrackState {
        let trackGroup: TrackGroup
        let isAudioOrVideo: Bool
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
