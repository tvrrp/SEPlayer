//
//  FakeMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import Foundation
import Testing
@testable import SEPlayer

final class FakeMediaPeriod: MediaPeriod {
    var trackGroups: [TrackGroup]
    let isLoading: Bool = false

    private let queue: Queue
    private let sampleStreams: NSHashTable<FakeSampleStream>
    private let trackDataFactory: TrackDataFactory
    private let syncSampleTimestampsUs: [Int64]?
    private let allocator: Allocator
//    private let fakePreparationLoadTaskId: Int

    private var prepareCallback: (any MediaPeriodCallback)?
    private var deferOnPrepared = false
    private var prepared = false
    private var seekOffsetUs = Int64.zero
    private var discontinuityPositionUs = Int64.zero
    private var lastSeekPositionUs = Int64.zero

    convenience init(
        queue: Queue,
        trackGroups: [TrackGroup],
        allocator: Allocator,
        singleSampleTimeUs: Int64,
        deferOnPrepared: Bool = false
    ) throws {
        try self.init(
            queue: queue,
            trackGroups: trackGroups,
            allocator: allocator,
            trackDataFactory: DefaultTrackDataFactory.singleSampleWithTimeUs(sampleTimeUs: singleSampleTimeUs),
            deferOnPrepared: deferOnPrepared
        )
    }

    init(
        queue: Queue,
        trackGroups: [TrackGroup],
        allocator: Allocator,
        trackDataFactory: TrackDataFactory,
        syncSampleTimestampsUs: [Int64]? = nil,
        deferOnPrepared: Bool
    ) throws {
        self.queue = queue
        self.trackGroups = trackGroups
        self.deferOnPrepared = deferOnPrepared
        self.trackDataFactory = trackDataFactory
        if let syncSampleTimestampsUs {
            try #require(!syncSampleTimestampsUs.isEmpty)
        }
        self.syncSampleTimestampsUs = syncSampleTimestampsUs?.sorted()
        self.allocator = allocator
        sampleStreams = .init()
        discontinuityPositionUs = .timeUnset
    }

    func setDiscontinuityPositionUs(_ discontinuityPositionUs: Int64) {
        assert(queue.isCurrent())
        self.discontinuityPositionUs = discontinuityPositionUs
    }

    func setPreparationComplete() {
        assert(queue.isCurrent())
        deferOnPrepared = false
        finishPreparation()
    }

    func setSeekToUsOffset(_ seekOffsetUs: Int64) { self.seekOffsetUs = seekOffsetUs }

    func release() {
        assert(queue.isCurrent())
        prepared = false
        sampleStreams.allObjects.forEach { $0.release() }
        sampleStreams.removeAllObjects()
    }

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
        assert(queue.isCurrent())
        prepareCallback = callback
        if !deferOnPrepared {
            finishPreparation()
        }
    }

    func selectTrack(
        selections: [SETrackSelection?],
        mayRetainStreamFlags: [Bool],
        streams: inout [SampleStream?],
        streamResetFlags: inout [Bool],
        positionUs: Int64
    ) -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        for i in 0..<selections.count {
            if streams[i] != nil && (selections[i] == nil || !mayRetainStreamFlags[i]) {
                (streams[i] as? FakeSampleStream)?.release()
                sampleStreams.remove(streams[i] as? FakeSampleStream)
                streams[i] = nil
            }

            if streams[i] == nil, let selection = selections[i] {
                // TODO: assert(selection.count
                // TODO: other assertions
                let sampleStreamItems = trackDataFactory.create(
                    format: selection.selectedFormat,
                    mediaPeriodId: MediaPeriodId() // TODO: real mediaPeriodId
                )
                let sampleStream = createSampleStream(
                    allocator: allocator,
                    initialFormat: selection.selectedFormat,
                    fakeSampleStreamItems: sampleStreamItems
                )
                sampleStreams.add(sampleStream)
                streams[i] = sampleStream
                streamResetFlags[i] = true
            }
        }

        return seek(to: positionUs)
    }

    func discardBuffer(to position: Int64, toKeyframe: Bool) {
        assert(queue.isCurrent())
        sampleStreams.allObjects.forEach { $0.discardTo(positionUs: position, toKeyframe: toKeyframe) }
    }

    func reevaluateBuffer(positionUs: Int64) {}

    func readDiscontinuity() -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        let discontinuityPositionUs = self.discontinuityPositionUs
        self.discontinuityPositionUs = .timeUnset
        return discontinuityPositionUs
    }

    func getBufferedPositionUs() -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        guard !isLoadingFinished() else {
            return .endOfSource
        }

        var minBufferedPositionUs = Int64.max
        for sampleStream in sampleStreams.allObjects {
            minBufferedPositionUs = min(minBufferedPositionUs, sampleStream.getLargestQueuedTimestampUs())
        }

        return minBufferedPositionUs == .min ? lastSeekPositionUs : minBufferedPositionUs
    }

    func seek(to position: Int64) -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        let seekPositionUs = position + seekOffsetUs
        lastSeekPositionUs = seekPositionUs
        var seekedInsideStreams = true
        for sampleStream in sampleStreams.allObjects {
            seekedInsideStreams = seekedInsideStreams && sampleStream.seekTo(positionUs: seekPositionUs, allowTimeBeyondBuffer: isLoadingFinished())
        }
        if !seekedInsideStreams {
            for sampleStream in sampleStreams.allObjects {
                sampleStream.reset()
            }
        }
        return seekPositionUs
    }

    func getAdjustedSeekPositionUs(positionUs: Int64, seekParameters: SeekParameters) -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        let adjustedPositionUs: Int64
        if let syncSampleTimestampsUs {
            let firstSyncTimestampIndex = Util.binarySearch(
                array: syncSampleTimestampsUs,
                value: positionUs,
                inclusive: true,
                stayInBounds: false
            )
            assert(firstSyncTimestampIndex >= 0)
            let firstSyncUs = syncSampleTimestampsUs[firstSyncTimestampIndex]
            let secondSyncUs = if firstSyncTimestampIndex < syncSampleTimestampsUs.count - 1 {
                syncSampleTimestampsUs[firstSyncTimestampIndex + 1]
            } else {
                firstSyncUs
            }

            adjustedPositionUs = seekParameters.resolveSyncPosition(
                positionUs: positionUs,
                firstSyncUs: firstSyncUs,
                secondSyncUs: secondSyncUs
            )
        } else {
            adjustedPositionUs = positionUs
        }

        return adjustedPositionUs + seekOffsetUs
    }

    func getNextLoadPositionUs() -> Int64 {
        assert(queue.isCurrent()); assert(prepared)
        return getBufferedPositionUs()
    }

    @TestableSyncPlayerActor
    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        assert(queue.isCurrent())
        var progressMade = false
        for sampleStream in sampleStreams.allObjects {
            try! sampleStream.writeData(
                startPositionUs: loadingInfo.playbackPosition,
                isolation: TestableSyncPlayerActor.shared
            )
            progressMade = true
        }
        return progressMade
    }

    func createSampleStream(
        allocator: Allocator,
        initialFormat: Format,
        fakeSampleStreamItems: [FakeSampleStream.FakeSampleStreamItem]
    ) -> FakeSampleStream {
        FakeSampleStream(
            queue: queue,
            allocator: allocator,
            initialFormat: initialFormat,
            fakeSampleStreamItems: fakeSampleStreamItems
        )
    }

    private func finishPreparation() {
        prepared = true
        prepareCallback?.didPrepare(mediaPeriod: self)
    }

    private func isLoadingFinished() -> Bool {
        sampleStreams.allObjects.allSatisfy(\.loadingFinished)
    }
}

extension FakeMediaPeriod {
    protocol TrackDataFactory {
        func create(format: Format, mediaPeriodId: MediaPeriodId) -> [FakeSampleStream.FakeSampleStreamItem]
    }

    struct DefaultTrackDataFactory: TrackDataFactory {
        private let samples: [FakeSampleStream.FakeSampleStreamItem]

        static func singleSampleWithTimeUs(sampleTimeUs: Int64) -> Self {
            .init(samples: [.init(oneByteSample: sampleTimeUs, flags: .keyframe), .endOfStream])
        }

        static func samplesWithRateDurationAndKeyframeInterval(
            initialSampleTimeUs: Int64,
            sampleRate: Float,
            durationUs: Int64,
            keyFrameInterval: Int
        ) -> Self {
            var samples = [FakeSampleStream.FakeSampleStreamItem]()
            for frameIndex in 0..<(durationUs / 33_333) {
                let frameTimeUs = initialSampleTimeUs + Int64((Float(frameIndex * .microsecondsPerSecond) / sampleRate).rounded(.down))
                samples.append(.init(
                    oneByteSample: frameTimeUs,
                    flags: Int(frameIndex) % keyFrameInterval == 0 ? .keyframe : []
                ))
            }
            samples.append(.endOfStream)

            return self.init(samples: samples)
        }

        func create(format: Format, mediaPeriodId: MediaPeriodId) -> [FakeSampleStream.FakeSampleStreamItem] {
            samples
        }
    }
}

private extension DataSpec {
    static let fakeDataSpec = DataSpec.spec(from: URL(string: "http://fake.test")!)
}
