//
//  FakeMediaPeriod.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.11.2025.
//

import CoreMedia
import Foundation
@testable import SEPlayer
import Testing

final class FakeMediaPeriod: MediaPeriod {
    func maybeThrowPrepareError() throws {}

    var trackGroups: TrackGroupArray
    let isLoading: Bool = false
    /// Whether streams take new selections of their group, as HLS variants do.
    var allowsSelectionUpdatesKeepingBuffer = false
    private(set) var selectionUpdatesKeepingBuffer = 0
    private(set) var createdStreamCount = 0

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
        trackGroups: TrackGroupArray,
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
        trackGroups: TrackGroupArray,
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

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
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
        position: CMTime
    ) throws -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        for i in 0 ..< selections.count {
            if streams[i] != nil && (selections[i] == nil || !mayRetainStreamFlags[i]) {
                (streams[i] as? FakeSampleStream)?.release()
                sampleStreams.remove(streams[i] as? FakeSampleStream)
                streams[i] = nil
            }

            if streams[i] != nil, selections[i] != nil, allowsSelectionUpdatesKeepingBuffer {
                // A kept stream starts over with the media of its new selection.
                streamResetFlags[i] = true
            }

            if streams[i] == nil, let selection = selections[i] {
                createdStreamCount += 1
                // TODO: assert(selection.count
                // TODO: other assertions
                let sampleStreamItems = trackDataFactory.create(
                    format: selection.selectedFormat,
                    mediaPeriodId: MediaPeriodId() // TODO: real mediaPeriodId
                )
                let sampleStream = try createSampleStream(
                    initialFormat: selection.selectedFormat,
                    fakeSampleStreamItems: sampleStreamItems
                )
                sampleStreams.add(sampleStream)
                streams[i] = sampleStream
                streamResetFlags[i] = true
            }
        }

        return try seek(position: position)
    }

    var keepsStreamsForSelectionsInSameGroup: Bool { allowsSelectionUpdatesKeepingBuffer }

    func updateSelectionsKeepingBuffer(_ selections: [SETrackSelection?], streams: [SampleStream?]) -> Bool {
        assert(queue.isCurrent())
        guard allowsSelectionUpdatesKeepingBuffer else { return false }
        selectionUpdatesKeepingBuffer += 1
        return true
    }

    func discardBuffer(position: CMTime, toKeyframe: Bool) throws {
        assert(queue.isCurrent())
        try sampleStreams.allObjects.forEach { try $0.discardTo(positionUs: position.microseconds, toKeyframe: toKeyframe) }
    }

    func reevaluateBuffer(position: CMTime) {}

    func readDiscontinuity() -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        let discontinuityPositionUs = self.discontinuityPositionUs
        self.discontinuityPositionUs = .timeUnset
        return .time(us: discontinuityPositionUs)
    }

    func getBufferedPosition() -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        guard !isLoadingFinished() else {
            return .positiveInfinity
        }

        var minBufferedPosition = CMTime.positiveInfinity
        for sampleStream in sampleStreams.allObjects {
            minBufferedPosition = min(minBufferedPosition, sampleStream.getLargestQueuedTimestamp())
        }

        return minBufferedPosition == .negativeInfinity ? .time(us: lastSeekPositionUs) : minBufferedPosition
    }

    func seek(position: CMTime) throws -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        let seekPositionUs = position.microseconds + seekOffsetUs
        lastSeekPositionUs = seekPositionUs
        var seekedInsideStreams = true
        for sampleStream in sampleStreams.allObjects {
            seekedInsideStreams = seekedInsideStreams && sampleStream.seekTo(positionUs: seekPositionUs, allowTimeBeyondBuffer: isLoadingFinished())
        }
        if !seekedInsideStreams {
            for sampleStream in sampleStreams.allObjects {
                try sampleStream.reset()
            }
        }
        return .time(us: seekPositionUs)
    }

    func seekForRecovery(position: CMTime) throws -> CMTime {
        try seek(position: position)
    }

    func getAdjustedSeekPosition(position: CMTime, seekParameters: SeekParameters) -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        let positionUs = position.microseconds
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
                position: .time(us: positionUs),
                firstSync: .time(us: firstSyncUs),
                secondSync: .time(us: secondSyncUs)
            ).microseconds
        } else {
            adjustedPositionUs = positionUs
        }

        return .time(us: adjustedPositionUs + seekOffsetUs)
    }

    func getNextLoadPosition() -> CMTime {
        assert(queue.isCurrent()); assert(prepared)
        return getBufferedPosition()
    }

    func continueLoading(with loadingInfo: LoadingInfo) -> Bool {
        assert(queue.isCurrent())
        var progressMade = false
        queue.playerActor().assumeIsolated { isolation in
            for sampleStream in sampleStreams.allObjects {
                // From where the period starts or was sought to: a period that loads ahead of playback starts after
                // the playback position.
                do {
                    try sampleStream.writeData(
                        startPositionUs: lastSeekPositionUs,
                        isolation: isolation
                    )
                    progressMade = true
                } catch {
                    Issue.record(error)
                }
            }
        }
        return progressMade
    }

    func stopLoading() {}

    func createSampleStream(
        initialFormat: AnyFormat,
        fakeSampleStreamItems: [FakeSampleStream.FakeSampleStreamItem]
    ) throws -> FakeSampleStream {
        try FakeSampleStream(
            queue: queue,
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
        func create(format: AnyFormat, mediaPeriodId: MediaPeriodId) -> [FakeSampleStream.FakeSampleStreamItem]
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
            for frameIndex in 0 ..< (durationUs / 33_333) {
                let frameTimeUs = initialSampleTimeUs + Int64((Float(frameIndex * .microsecondsPerSecond) / sampleRate).rounded(.down))
                samples.append(.init(
                    oneByteSample: frameTimeUs,
                    flags: Int(frameIndex) % keyFrameInterval == 0 ? .keyframe : []
                ))
            }
            samples.append(.endOfStream)

            return self.init(samples: samples)
        }

        func create(format: AnyFormat, mediaPeriodId: MediaPeriodId) -> [FakeSampleStream.FakeSampleStreamItem] {
            samples
        }
    }
}
