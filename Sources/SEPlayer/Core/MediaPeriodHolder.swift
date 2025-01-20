//
//  MediaPeriodHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia

final class MediaPeriodHolder {
    let queue: Queue
    let mediaPeriod: any MediaPeriod
    var sampleStreams: [SampleStream] = []
    let info: MediaPeriodInfo
    let mediaSourceList: MediaSourceList
    let trackSelector: TrackSelector

    var trackGroups: [TrackGroup] = []
    var prepareCalled: Bool = false
    var isPrepared: Bool = false
    var hasEnabledTracks: Bool = false

    init(
        queue: Queue,
        allocator: Allocator,
        mediaSourceList: MediaSourceList,
        info: MediaPeriodInfo,
        loadCondition: LoadConditionCheckable,
        trackSelector: TrackSelector
    ) {
        self.queue = queue
        self.mediaSourceList = mediaSourceList
        self.info = info
        self.trackSelector = trackSelector

        self.mediaPeriod = mediaSourceList.createPeriod(
            id: info.id, allocator: allocator, loadCondition: loadCondition, startPosition: info.startPosition
        )
    }

    func handlePrepared(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool, delegate: SampleQueueDelegate) {
        assert(queue.isCurrent())
        isPrepared = true
        trackGroups = mediaPeriod.trackGroups
        let trackGroups = mediaPeriod.trackGroups
        let requestedStartPosition = info.startPosition
        let selectorResult = selectTracks(playbackSpeed: playbackSpeed, timeline: timeline, playWhenReady: playWhenReady)
        applyTrackSelection(trackSelectorResult: selectorResult, time: requestedStartPosition, delegate: delegate)
    }

    func applyTrackSelection(trackSelectorResult: TrackSelectionResult, time: CMTime, delegate: SampleQueueDelegate) {
        assert(queue.isCurrent())
        sampleStreams = mediaPeriod.selectTrack(selections: trackSelectorResult.selections, on: time, delegate: delegate)
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
        mediaPeriod.prepare(callback: callback, on: time)
    }
}

extension MediaPeriodHolder {
    func selectTracks(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) -> TrackSelectionResult {
        let selectorResult = trackSelector.selectTracks(
            trackGroups: trackGroups, periodId: info.id, timeline: timeline
        )
        return selectorResult
    }
}

extension MediaPeriodHolder {
    func releaseMediaPerion(mediaSourceList: MediaSourceList, mediaPeriod: MediaPeriod) {
        mediaSourceList.releasePeriod(mediaPeriod: mediaPeriod)
    }
}
