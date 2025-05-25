//
//  MediaPeriodHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import Foundation

final class MediaPeriodHolder {
    var allRenderersInCorrectState: Bool = false
    var renderPositionOffset: Int64 = 0
    var trackSelectorResults: TrackSelectionResult
    
    let queue: Queue
    let mediaPeriod: any MediaPeriod
    let id: AnyHashable
    let rendererCapabilities: [RendererCapabilities]
    
    var sampleStreams: [SampleStream?]
    let targetPreloadBufferDurationUs: Int64
    var info: MediaPeriodInfo
    let mediaSourceList: MediaSourceList
    let trackSelector: TrackSelector
    
    var trackGroups: [TrackGroup] = []
    var prepareCalled: Bool = false
    var isPrepared: Bool = false
    var hasEnabledTracks: Bool = false
    
    var next: MediaPeriodHolder?
    
    private var mayRetainStreamFlags: [Bool]
    
    init(
        queue: Queue,
        rendererCapabilities: [RendererCapabilities],
        allocator: Allocator,
        mediaSourceList: MediaSourceList,
        info: MediaPeriodInfo,
        trackSelector: TrackSelector,
        emptyTrackSelectorResult: TrackSelectionResult,
        targetPreloadBufferDurationUs: Int64
    ) throws {
        self.queue = queue
        self.rendererCapabilities = rendererCapabilities
        self.sampleStreams = Array(repeating: nil, count: rendererCapabilities.count)
        self.targetPreloadBufferDurationUs = targetPreloadBufferDurationUs
        self.mayRetainStreamFlags = Array(repeating: false, count: rendererCapabilities.count)
        self.mediaSourceList = mediaSourceList
        self.info = info
        self.id = info.id.periodId
        self.trackSelector = trackSelector
        self.trackSelectorResults = emptyTrackSelectorResult
        
        self.mediaPeriod = try Self.createMediaPeriod(
            id: info.id,
            mediaSourceList: mediaSourceList,
            allocator: allocator,
            startPositionUs: info.startPositionUs,
            endPositionUs: info.endPositionUs
        )
    }
    
    func toRendererTime(periodTime: Int64) -> Int64 {
        periodTime + renderPositionOffset
    }
    
    func toPeriodTime(rendererTime: Int64) -> Int64 {
        rendererTime - renderPositionOffset
    }
    
    func getStartPositionRenderTime() -> Int64 {
        info.startPositionUs + renderPositionOffset
    }
    
    func isFullyBuffered() -> Bool {
        return isPrepared && (!hasEnabledTracks || mediaPeriod.getBufferedPositionUs() == .endOfSource )
    }
    
    func isFullyPreloaded() -> Bool {
        return isPrepared &&
            isFullyBuffered() || getBufferedPositionUs() - info.startPositionUs >= targetPreloadBufferDurationUs
    }

    func getBufferedPositionUs() -> Int64 {
        guard isPrepared else { return info.startPositionUs }

        let bufferedPosition = hasEnabledTracks ? mediaPeriod.getBufferedPositionUs() : .endOfSource
        return bufferedPosition == .endOfSource ? info.durationUs : bufferedPosition
    }

    func getNextLoadPosition() -> Int64 {
        !isPrepared ? .zero : mediaPeriod.getNextLoadPositionUs()
    }

    func handlePrepared(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) {
        assert(queue.isCurrent())
        isPrepared = true
        trackGroups = mediaPeriod.trackGroups
        let selectorResult = selectTracks(
            playbackSpeed: playbackSpeed,
            timeline: timeline,
            playWhenReady: playWhenReady
        )
        var requestedStartPosition = info.startPositionUs
        if info.durationUs != .timeUnset && requestedStartPosition >= info.durationUs {
            requestedStartPosition = max(0, info.durationUs - 1)
        }
        let newStartPosition = applyTrackSelection(trackSelectorResult: selectorResult,
                                                   positionUs: requestedStartPosition,
                                                   forceRecreateStreams: false)
        renderPositionOffset += info.startPositionUs - newStartPosition
        info = info.copyWithStartPositionUs(newStartPosition)
    }

    func reevaluateBuffer(rendererPosition: Int64) {
        if isPrepared {
            mediaPeriod.reevaluateBuffer(positionUs: toPeriodTime(rendererTime: rendererPosition))
        }
    }

    func continueLoading(loadingInfo: LoadingInfo) {
        mediaPeriod.continueLoading(with: loadingInfo)
    }

    func selectTracks(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) -> TrackSelectionResult {
        let selectorResult = trackSelector.selectTracks(
            rendererCapabilities: rendererCapabilities,
            trackGroups: trackGroups,
            periodId: info.id,
            timeline: timeline
        )
        return selectorResult
    }

    func applyTrackSelection(
        trackSelectorResult: TrackSelectionResult,
        positionUs: Int64,
        forceRecreateStreams: Bool
    ) -> Int64 {
        assert(queue.isCurrent())
        var streamResetFlags = Array(repeating: false, count: rendererCapabilities.count)
        return applyTrackSelection(
            newTrackSelectorResult: trackSelectorResult,
            positionUs: positionUs,
            forceRecreateStreams: forceRecreateStreams,
            streamResetFlags: &streamResetFlags
        )
    }

    func applyTrackSelection(
        newTrackSelectorResult: TrackSelectionResult,
        positionUs: Int64,
        forceRecreateStreams: Bool,
        streamResetFlags: inout [Bool]
    ) -> Int64 {
        for index in 0..<newTrackSelectorResult.selections.count {
            mayRetainStreamFlags[index] = !forceRecreateStreams
                && trackSelectorResults == newTrackSelectorResult
        }

        self.trackSelectorResults = newTrackSelectorResult
        return mediaPeriod.selectTrack(
            selections: newTrackSelectorResult.selections,
            mayRetainStreamFlags: mayRetainStreamFlags,
            streams: &sampleStreams,
            streamResetFlags: &streamResetFlags,
            positionUs: positionUs
        )
    }

    func release() {
        disableTrackSelectionsInResult()
        releaseMediaPeriod(mediaSourceList: mediaSourceList, mediaPeriod: mediaPeriod)
    }

    func setNext(_ mediaPeriodHolder: MediaPeriodHolder?) {
        guard let mediaPeriodHolder else { return }

        disableTrackSelectionsInResult()
        next = mediaPeriodHolder
        enableTrackSelectionsInResult()
    }

    func canBeUsedFor(mediaPeriodInfo: MediaPeriodInfo) -> Bool {
        Self.durationsCompatible(lhs: self.info.durationUs, rhs: mediaPeriodInfo.durationUs)
            && self.info.startPositionUs == info.startPositionUs
            && self.info.id == mediaPeriodInfo.id
    }

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
        prepareCalled = true
        mediaPeriod.prepare(callback: callback, on: time)
    }

    private func enableTrackSelectionsInResult() {
        guard isLoadingMediaPeriod() else { return }

        for (index, selection) in trackSelectorResults.selections.enumerated() {
            let rendererEnabled = trackSelectorResults.isRendererEnabled(for: index)
            if rendererEnabled, let selection {
                selection.enable()
            }
        }
    }

    private func disableTrackSelectionsInResult() {
        guard isLoadingMediaPeriod() else { return }

        for (index, selection) in trackSelectorResults.selections.enumerated() {
            let rendererEnabled = trackSelectorResults.isRendererEnabled(for: index)
            if !rendererEnabled, let selection {
                selection.disable()
            }
        }
    }

    func disassociateNoSampleRenderersWithEmptySampleStream(sampleStreams: inout [SampleStream?]) {
        for (index, capability) in rendererCapabilities.enumerated() {
            if capability.trackType == .unknown {
                sampleStreams[index] = nil
            }
        }
    }

    func associateNoSampleRenderersWithEmptySampleStream(sampleStreams: inout [SampleStream?]) {
        for (index, capability) in rendererCapabilities.enumerated() {
            if capability.trackType == .unknown, trackSelectorResults.isRendererEnabled(for: index) {
                sampleStreams[index] = EmptySampleStream()
            }
        }
    }

    private func isLoadingMediaPeriod() -> Bool {
        next == nil
    }

    private static func createMediaPeriod(
        id: MediaPeriodId,
        mediaSourceList: MediaSourceList,
        allocator: Allocator,
        startPositionUs: Int64,
        endPositionUs: Int64
    ) throws -> MediaPeriod {
        let mediaPeriod = try mediaSourceList.createPeriod(
            id: id,
            allocator: allocator,
            startPosition: startPositionUs
        )

        if endPositionUs != .timeUnset {
            // TODO: clipping
        }

        return mediaPeriod
    }

    private func releaseMediaPeriod(mediaSourceList: MediaSourceList, mediaPeriod: MediaPeriod) {
        mediaSourceList.releasePeriod(mediaPeriod: mediaPeriod)
    }
}

extension MediaPeriodHolder: Equatable {
    static func == (lhs: MediaPeriodHolder, rhs: MediaPeriodHolder) -> Bool {
        return lhs === rhs
    }
}

extension MediaPeriodHolder {
    static func durationsCompatible(lhs: Int64, rhs: Int64) -> Bool {
        lhs == .timeUnset || lhs == rhs
    }
}
