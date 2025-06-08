//
//  PlaybackInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.05.2025.
//

import CoreMedia.CMSync

struct PlaybackInfo {
    private(set) var clock: CMClock
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

    var isPlaying: Bool { state == .ready && playWhenReady }

    static func dummy(clock: CMClock, emptyTrackSelectorResult: TrackSelectionResult) -> PlaybackInfo {
        PlaybackInfo(
            clock: clock,
            timeline: EmptyTimeline(),
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
        newValue.timeline = timeline
        return newValue
    }

    func playbackState(_ state: PlayerState) -> PlaybackInfo {
        var newValue = self
        newValue.state = state
        return newValue
    }

    func setPlaybackError(_ playbackError: Error?) -> Self {
        var newValue = self
        newValue.playbackError = playbackError
        return newValue
    }

    func isLoading(_ isLoading: Bool) -> Self {
        var newValue = self
        newValue.isLoading = isLoading
        return newValue
    }

    func loadingMediaPeriodId(_ loadingMediaPeriodId: MediaPeriodId) -> Self {
        var newValue = self
        newValue.loadingMediaPeriodId = loadingMediaPeriodId
        return newValue
    }

    func playWhenReady(
        _ playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason
    ) -> Self {
        var newValue = self
        newValue.playWhenReady = playWhenReady
        newValue.playWhenReadyChangeReason = playWhenReadyChangeReason
        newValue.playbackSuppressionReason = playbackSuppressionReason
        return newValue
    }

    func playbackParameters(_ playbackParameters: PlaybackParameters) -> Self {
        var newValue = self
        newValue.playbackParameters = playbackParameters
        return newValue
    }

    func estimatedPosition() -> Self {
        var newValue = self
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
        lhs.timeline.equals(to: rhs.timeline) &&
        lhs.periodId == rhs.periodId &&
        lhs.requestedContentPositionUs == rhs.requestedContentPositionUs &&
        lhs.discontinuityStartPositionUs == rhs.discontinuityStartPositionUs &&
        lhs.state == rhs.state &&
        lhs.playbackError != nil && rhs.playbackError == nil &&
        lhs.playbackError == nil && rhs.playbackError != nil &&
        lhs.isLoading == rhs.isLoading &&
        lhs.trackGroups == rhs.trackGroups &&
        lhs.trackSelectorResult == rhs.trackSelectorResult &&
        lhs.loadingMediaPeriodId == rhs.loadingMediaPeriodId &&
        lhs.playWhenReady == rhs.playWhenReady &&
        lhs.playWhenReadyChangeReason == rhs.playWhenReadyChangeReason &&
        lhs.playbackSuppressionReason == rhs.playbackSuppressionReason &&
        lhs.playbackParameters == rhs.playbackParameters &&
        lhs.bufferedPositionUs == rhs.bufferedPositionUs &&
        lhs.totalBufferedDurationUs == rhs.totalBufferedDurationUs &&
        lhs.positionUs == rhs.positionUs &&
        lhs.positionUpdateTimeMs == rhs.positionUpdateTimeMs
    }
}

extension PlaybackInfo {
    static let placeholderMediaPeriodId = MediaPeriodId()
}
