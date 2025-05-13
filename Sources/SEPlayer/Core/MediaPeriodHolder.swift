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

    private var mayRetainStreamFlags: [Bool]
    private var trackSelectorResults: TrackSelectionResult?

    init(
        queue: Queue,
        rendererCapabilities: [RendererCapabilities],
        allocator: Allocator,
        mediaSourceList: MediaSourceList,
        info: MediaPeriodInfo,
        trackSelector: TrackSelector
    ) {
        self.queue = queue
        self.rendererCapabilities = rendererCapabilities
        self.sampleStreams = Array(repeating: nil, count: rendererCapabilities.count)
        self.mayRetainStreamFlags = Array(repeating: false, count: rendererCapabilities.count)
        self.mediaSourceList = mediaSourceList
        self.info = info
        self.trackSelector = trackSelector

        self.mediaPeriod = mediaSourceList.createPeriod(
            id: info.id, allocator: allocator, startPosition: info.startPosition
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
        return isPrepared && (!hasEnabledTracks || mediaPeriod.getBufferedPositionUs() == .endOfSource )
    }

    func isFullyPreloaded() -> Bool {
        return false
        // TODO: return isPrepared &&
            //(isFullyBuffered() || getBufferedPosition() - info.startPosition >= tar)
    }

    func getBufferedPosition() -> Int64 {
        guard isPrepared else { return info.startPosition }

        let bufferedPosition = hasEnabledTracks ? mediaPeriod.getBufferedPositionUs() : .endOfSource
        return bufferedPosition == .endOfSource ? info.duration : bufferedPosition
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
        var requestedStartPosition = info.startPosition
        if info.duration != .timeUnset && requestedStartPosition >= info.duration {
            requestedStartPosition = max(0, info.duration - 1)
        }
        let newStartPosition = applyTrackSelection(trackSelectorResult: selectorResult,
                                                   positionUs: requestedStartPosition,
                                                   forceRecreateStreams: false)
        renderPositionOffset += info.startPosition - newStartPosition
        info = info.withUpdatedStartPosition(newStartPosition)
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

    func prepare(callback: any MediaPeriodCallback, on time: Int64) {
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
