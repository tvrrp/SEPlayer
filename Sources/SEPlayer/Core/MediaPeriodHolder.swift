//
//  MediaPeriodHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia

final class MediaPeriodHolder {
    var renderPositionOffset: Int64 = 0

    let queue: Queue
    let mediaPeriod: any MediaPeriod
    let rendererCapabilities: [RendererCapabilities]

    var sampleStreams: [SampleStream?]
    var info: MediaPeriodInfo
    let mediaSourceList: MediaSourceList
    let trackSelector: TrackSelector

    var trackGroups: [TrackGroup] = []
    var prepareCalled: Bool = false
    var isPrepared: Bool = false
    var hasEnabledTracks: Bool = false

    init(
        queue: Queue,
        rendererCapabilities: [RendererCapabilities],
        allocator: Allocator,
        mediaSourceList: MediaSourceList,
        info: MediaPeriodInfo,
        loadCondition: LoadConditionCheckable,
        trackSelector: TrackSelector
    ) {
        self.queue = queue
        self.rendererCapabilities = rendererCapabilities
        self.sampleStreams = Array(repeating: nil, count: rendererCapabilities.count)
        self.mediaSourceList = mediaSourceList
        self.info = info
        self.trackSelector = trackSelector

        self.mediaPeriod = mediaSourceList.createPeriod(
            id: info.id, allocator: allocator, loadCondition: loadCondition, startPosition: info.startPosition
        )
    }

    func toRendererTime(periodTime: Int64) -> Int64 {
        periodTime + renderPositionOffset
    }

    func toPeriodTime(rendererTime: Int64) -> Int64 {
        rendererTime - renderPositionOffset
    }

    func getStartPositionRenderTime() -> Int64 {
        info.startPosition + renderPositionOffset
    }

    func isFullyBuffered() -> Bool {
        return isPrepared && (!hasEnabledTracks || mediaPeriod.bufferedPosition == .endOfSource )
    }

    func isFullyPreloaded() -> Bool {
        return false
        // TODO: return isPrepared &&
            //(isFullyBuffered() || getBufferedPosition() - info.startPosition >= tar)
    }

    func getBufferedPosition() -> Int64 {
        guard isPrepared else { return info.startPosition }

        let bufferedPosition = hasEnabledTracks ? mediaPeriod.bufferedPosition : .endOfSource
        return bufferedPosition == .endOfSource ? info.duration : bufferedPosition
    }

    func getNextLoadPosition() -> Int64 {
        !isPrepared ? .zero : mediaPeriod.nextLoadPosition
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
        var requestedStartPosition = info.startPosition
        if info.duration != .timeUnset && requestedStartPosition >= info.duration {
            requestedStartPosition = max(0, info.duration - 1)
        }
        let newStartPosition = applyTrackSelection(trackSelectorResult: selectorResult,
                                                   position: requestedStartPosition,
                                                   forceRecreateStreams: false)
        renderPositionOffset += info.startPosition - newStartPosition
        info = info.withUpdatedStartPosition(newStartPosition)
    }

    func reevaluateBuffer(rendererPosition: Int64) {
        if isPrepared {
            // TODO: mediaPeriod.reevaluateBuffer
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
        position: Int64,
        forceRecreateStreams: Bool
    ) -> Int64 {
        assert(queue.isCurrent())
        return applyTrackSelection(
            newTrackSelectorResult: trackSelectorResult,
            position: position,
            forceRecreateStreams: forceRecreateStreams,
            streamResetFlags: Array(repeating: false, count: rendererCapabilities.count)
        )
    }

    func applyTrackSelection(
        newTrackSelectorResult: TrackSelectionResult,
        position: Int64,
        forceRecreateStreams: Bool,
        streamResetFlags: [Bool]
    ) -> Int64 {
        fatalError()
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        mediaPeriod.prepare(callback: callback, on: time)
    }
}

extension MediaPeriodHolder {
    
}

extension MediaPeriodHolder {
    func releaseMediaPerion(mediaSourceList: MediaSourceList, mediaPeriod: MediaPeriod) {
        mediaSourceList.releasePeriod(mediaPeriod: mediaPeriod)
    }
}
