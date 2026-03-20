//
//  PlaybackInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 13.05.2025.
//

import CoreMedia.CMSync
import SEPlayerCommon

struct PlaybackInfo {
    private(set) var clock: SEClock
    private(set) var timeline: Timeline
    private(set) var periodId: MediaPeriodId
    private(set) var requestedContentPosition: CMTime
    private(set) var discontinuityStartPosition: CMTime
    private(set) var state: PlayerState
    private(set) var playbackError: Error?
    private(set) var isLoading: Bool
    private(set) var trackGroups: TrackGroupArray
    private(set) var trackSelectorResult: TrackSelectorResult
    private(set) var loadingMediaPeriodId: MediaPeriodId
    private(set) var playWhenReady: Bool
    private(set) var playWhenReadyChangeReason: PlayWhenReadyChangeReason
    private(set) var playbackSuppressionReason: PlaybackSuppressionReason
    private(set) var playbackParameters: PlaybackParameters
    var bufferedPosition: CMTime
    var totalBufferedDuration: CMTime
    private(set) var position: CMTime
    private(set) var positionUpdateTime: CMTime

    var object = NSObject()

    var isPlaying: Bool { state == .ready && playWhenReady }

    init(
        clock: SEClock,
        timeline: Timeline,
        periodId: MediaPeriodId,
        requestedContentPosition: CMTime,
        discontinuityStartPosition: CMTime,
        state: PlayerState,
        playbackError: Error? = nil,
        isLoading: Bool,
        trackGroups: TrackGroupArray,
        trackSelectorResult: TrackSelectorResult,
        loadingMediaPeriodId: MediaPeriodId,
        playWhenReady: Bool,
        playWhenReadyChangeReason: PlayWhenReadyChangeReason,
        playbackSuppressionReason: PlaybackSuppressionReason,
        playbackParameters: PlaybackParameters,
        bufferedPosition: CMTime,
        totalBufferedDuration: CMTime,
        position: CMTime,
        positionUpdateTime: CMTime,
        object: NSObject = NSObject()
    ) {
        self.clock = clock
        self.timeline = timeline
        self.periodId = periodId
        self.requestedContentPosition = requestedContentPosition
        self.discontinuityStartPosition = discontinuityStartPosition
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
        self.bufferedPosition = bufferedPosition
        self.totalBufferedDuration = totalBufferedDuration
        self.position = position
        self.positionUpdateTime = positionUpdateTime
        self.object = object
    }

    static func dummy(clock: SEClock, emptyTrackSelectorResult: TrackSelectorResult) -> PlaybackInfo {
        PlaybackInfo(
            clock: clock,
            timeline: emptyTimeline,
            periodId: PlaybackInfo.placeholderMediaPeriodId,
            requestedContentPosition: .invalid,
            discontinuityStartPosition: .zero,
            state: .idle,
            playbackError: nil,
            isLoading: false,
            trackGroups: TrackGroupArray.empty,
            trackSelectorResult: emptyTrackSelectorResult,
            loadingMediaPeriodId: PlaybackInfo.placeholderMediaPeriodId,
            playWhenReady: false,
            playWhenReadyChangeReason: .userRequest,
            playbackSuppressionReason: .none,
            playbackParameters: .default,
            bufferedPosition: .zero,
            totalBufferedDuration: .zero,
            position: .zero,
            positionUpdateTime: .zero
        )
    }

    func setPosition(_ position: CMTime) -> Self {
        var newValue = self
        newValue.object = NSObject()
        newValue.position = position
        newValue.positionUpdateTime = clock.time
        return newValue
    }

    func setPosition(
        periodId: MediaPeriodId,
        position: CMTime,
        requestedContentPosition: CMTime,
        discontinuityStartPosition: CMTime,
        totalBufferedDuration: CMTime,
        trackGroups: TrackGroupArray,
        trackSelectorResult: TrackSelectorResult
    ) -> PlaybackInfo {
        var newValue = self
        newValue.object = NSObject()
        newValue.periodId = periodId
        newValue.position = position
        newValue.requestedContentPosition = requestedContentPosition
        newValue.discontinuityStartPosition = discontinuityStartPosition
        newValue.totalBufferedDuration = totalBufferedDuration
        newValue.trackGroups = trackGroups
        newValue.trackSelectorResult = trackSelectorResult
        newValue.positionUpdateTime = clock.time
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
        newValue.position = getEstimatedPosition()
        newValue.positionUpdateTime = clock.time
        return newValue
    }

    func getEstimatedPosition() -> CMTime {
        guard isPlaying else { return position }

        let elapsed = clock.time - positionUpdateTime
        let estimatedPosition = position + CMTimeMultiplyByFloat64(elapsed, multiplier: Float64(playbackParameters.playbackRate))
        return estimatedPosition
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
