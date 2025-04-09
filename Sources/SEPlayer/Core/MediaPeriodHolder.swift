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
    let mediaSource: MediaSource
    let trackSelector: TrackSelector

    var trackGroups: [TrackGroup] = []
    var prepareCalled: Bool = false
    var isPrepared: Bool = false
    var hasEnabledTracks: Bool = false

    init(
        queue: Queue,
        allocator: Allocator,
        mediaSource: MediaSource,
        info: MediaPeriodInfo,
        loadCondition: LoadConditionCheckable,
        trackSelector: TrackSelector,
        mediaSourceEventDelegate: MediaSourceEventListener
    ) {
        self.queue = queue
        self.mediaSource = mediaSource
        self.info = info
        self.trackSelector = trackSelector

        self.mediaPeriod = mediaSource.createPeriod(
            allocator: allocator,
            startPosition: info.startPosition,
            loadCondition: loadCondition,
            mediaSourceEventDelegate: mediaSourceEventDelegate
        )
    }

    func handlePrepared(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) {
        assert(queue.isCurrent())
        isPrepared = true
        trackGroups = mediaPeriod.trackGroups
        let requestedStartPosition = info.startPosition
        let selectorResult = selectTracks(playbackSpeed: playbackSpeed, timeline: timeline, playWhenReady: playWhenReady)
        applyTrackSelection(trackSelectorResult: selectorResult, time: requestedStartPosition)
    }

    func applyTrackSelection(trackSelectorResult: TrackSelectionResult, time: CMTime) {
        assert(queue.isCurrent())
        sampleStreams = mediaPeriod.selectTrack(selections: trackSelectorResult.selections, on: time)
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
