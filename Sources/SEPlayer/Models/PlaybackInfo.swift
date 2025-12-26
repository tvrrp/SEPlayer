//
//  PlaybackInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.05.2025.
//

import CoreMedia.CMSync

struct PlaybackInfo {
    private(set) var clock: SEClock
    private(set) var timeline: Timeline
    private(set) var periodId: MediaPeriodId
    private(set) var requestedContentPositionUs: Int64
    private(set) var discontinuityStartPositionUs: Int64
    private(set) var state: PlayerState
    private(set) var playbackError: Error?
    private(set) var isLoading: Bool
    private(set) var trackGroups: [TrackGroup]
    private(set) var trackSelectorResult: TrackSelectionResult
    private(set) var loadingMediaPeriodId: MediaPeriodId
    private(set) var playWhenReady: Bool
    private(set) var playWhenReadyChangeReason: PlayWhenReadyChangeReason
    private(set) var playbackSuppressionReason: PlaybackSuppressionReason
    private(set) var playbackParameters: PlaybackParameters
    var bufferedPositionUs: Int64
    var totalBufferedDurationUs: Int64
    private(set) var positionUs: Int64
    private(set) var positionUpdateTimeMs: Int64

    var object = NSObject()

    var isPlaying: Bool { state == .ready && playWhenReady }

    init(
        clock: SEClock,
        timeline: Timeline,
        periodId: MediaPeriodId,
        requestedContentPositionUs: Int64,
        discontinuityStartPositionUs: Int64,
        state: PlayerState,
        playbackError: Error? = nil,
        isLoading: Bool,
        trackGroups: [TrackGroup],
        trackSelectorResult: TrackSelectionResult,
        loadingMediaPeriodId: MediaPeriodId,
        playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason,
        playbackParameters: PlaybackParameters,
        bufferedPositionUs: Int64,
        totalBufferedDurationUs: Int64,
        positionUs: Int64,
        positionUpdateTimeMs: Int64,
        object: NSObject = NSObject()
    ) {
        self.clock = clock
        self.timeline = timeline
        self.periodId = periodId
        self.requestedContentPositionUs = requestedContentPositionUs
        self.discontinuityStartPositionUs = discontinuityStartPositionUs
        self.state = state
        self.playbackError = playbackError
        self.isLoading = isLoading
        self.trackGroups = trackGroups
        self.trackSelectorResult = trackSelectorResult
        self.loadingMediaPeriodId = loadingMediaPeriodId
        self.playWhenReady = playWhenReady
        self.playWhenReadyChangeReason = playWhenReadyChangeReason
        self.playbackSuppressionReason = playbackSuppressionReason
        self.playbackParameters = playbackParameters
        self.bufferedPositionUs = bufferedPositionUs
        self.totalBufferedDurationUs = totalBufferedDurationUs
        self.positionUs = positionUs
        self.positionUpdateTimeMs = positionUpdateTimeMs
        self.object = object
    }

    static func dummy(clock: SEClock, emptyTrackSelectorResult: TrackSelectionResult) -> PlaybackInfo {
        PlaybackInfo(
            clock: clock,
            timeline: emptyTimeline,
            periodId: PlaybackInfo.placeholderMediaPeriodId,
            requestedContentPositionUs: .timeUnset,
            discontinuityStartPositionUs: .zero,
            state: .idle,
            playbackError: nil,
            isLoading: false,
            trackGroups: [],
            trackSelectorResult: emptyTrackSelectorResult,
            loadingMediaPeriodId: PlaybackInfo.placeholderMediaPeriodId,
            playWhenReady: false,
            playWhenReadyChangeReason: .userRequest,
            playbackSuppressionReason: .none,
            playbackParameters: .default,
            bufferedPositionUs: .zero,
            totalBufferedDurationUs: .zero,
            positionUs: .zero,
            positionUpdateTimeMs: .zero
        )
    }

    func positionUs(_ positionUs: Int64) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.positionUs = positionUs
        newValue.positionUpdateTimeMs = clock.milliseconds
        return newValue
    }

    func positionUs(
        periodId: MediaPeriodId,
        positionUs: Int64,
        requestedContentPositionUs: Int64,
        discontinuityStartPositionUs: Int64,
        totalBufferedDurationUs: Int64,
        trackGroups: [TrackGroup],
        trackSelectorResult: TrackSelectionResult
    ) -> PlaybackInfo {
        var newValue = self
        newValue.object = NSObject()
        newValue.periodId = periodId
        newValue.positionUs = positionUs
        newValue.requestedContentPositionUs = requestedContentPositionUs
        newValue.discontinuityStartPositionUs = discontinuityStartPositionUs
        newValue.totalBufferedDurationUs = totalBufferedDurationUs
        newValue.trackGroups = trackGroups
        newValue.trackSelectorResult = trackSelectorResult
        newValue.positionUpdateTimeMs = clock.milliseconds
        return newValue
    }

    func timeline(_ timeline: Timeline) -> PlaybackInfo {
        var newValue = self
        newValue.object = NSObject()
        newValue.timeline = timeline
        return newValue
    }

    func playbackState(_ state: PlayerState) -> PlaybackInfo {
        var newValue = self
        newValue.object = NSObject()
        newValue.state = state
        return newValue
    }

    func setPlaybackError(_ playbackError: Error?) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.playbackError = playbackError
        return newValue
    }

    func isLoading(_ isLoading: Bool) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.isLoading = isLoading
        return newValue
    }

    func loadingMediaPeriodId(_ loadingMediaPeriodId: MediaPeriodId) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.loadingMediaPeriodId = loadingMediaPeriodId
        return newValue
    }

    func playWhenReady(
        _ playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.playWhenReady = playWhenReady
        newValue.playWhenReadyChangeReason = playWhenReadyChangeReason
        newValue.playbackSuppressionReason = playbackSuppressionReason
        return newValue
    }

    func playbackParameters(_ playbackParameters: PlaybackParameters) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.playbackParameters = playbackParameters
        return newValue
    }

    func estimatedPosition() -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.positionUs = getEstimatedPositionUs()
        newValue.positionUpdateTimeMs = clock.milliseconds
        return newValue
    }

    func getEstimatedPositionUs() -> Int64 {
        guard isPlaying else { return positionUs }

        let elapsedTimeMs = clock.milliseconds - positionUpdateTimeMs
        let estimatedPositionMs = usToMs(elapsedTimeMs) + (elapsedTimeMs * Int64(playbackParameters.playbackRate))
        return msToUs(estimatedPositionMs)
    }

    private func usToMs(_ timeUs: Int64) -> Int64 {
        (timeUs == .timeUnset || timeUs == .endOfSource) ? timeUs : (timeUs / 1000);
    }

    private func msToUs(_ timeUs: Int64) -> Int64 {
        (timeUs == .timeUnset || timeUs == .endOfSource) ? timeUs : (timeUs * 1000);
    }
}

extension PlaybackInfo: Equatable {
    static func == (lhs: PlaybackInfo, rhs: PlaybackInfo) -> Bool {
        return lhs.object === rhs.object
//        return lhs.timeline.equals(to: rhs.timeline) &&
//            lhs.periodId == rhs.periodId &&
//            lhs.requestedContentPositionUs == rhs.requestedContentPositionUs &&
//            lhs.discontinuityStartPositionUs == rhs.discontinuityStartPositionUs &&
//            lhs.state == rhs.state &&
//            lhs.playbackError == nil && rhs.playbackError == nil &&
//            lhs.isLoading == rhs.isLoading &&
//            lhs.trackGroups == rhs.trackGroups &&
//            lhs.trackSelectorResult == rhs.trackSelectorResult &&
//            lhs.loadingMediaPeriodId == rhs.loadingMediaPeriodId &&
//            lhs.playWhenReady == rhs.playWhenReady &&
//            lhs.playWhenReadyChangeReason == rhs.playWhenReadyChangeReason &&
//            lhs.playbackSuppressionReason == rhs.playbackSuppressionReason &&
//            lhs.playbackParameters == rhs.playbackParameters &&
//            lhs.bufferedPositionUs == rhs.bufferedPositionUs &&
//            lhs.totalBufferedDurationUs == rhs.totalBufferedDurationUs &&
//            lhs.positionUs == rhs.positionUs //&&
//            lhs.positionUpdateTimeMs == rhs.positionUpdateTimeMs
    }
}

extension PlaybackInfo {
    static let placeholderMediaPeriodId = MediaPeriodId()
}
