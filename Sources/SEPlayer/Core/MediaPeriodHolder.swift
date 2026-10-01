//
//  MediaPeriodHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia
import SEPlayerCommon

final class MediaPeriodHolder {
    var allRenderersInCorrectState: Bool = false
    var renderPositionOffset: CMTime
    var trackSelectorResults: TrackSelectorResult

    let queue: Queue
    let mediaPeriod: any MediaPeriod
    let id: AnyHashable
    let rendererCapabilities: [RendererCapabilitiesResolver]

    var sampleStreams: [SampleStream?]
    let targetPreloadBufferDuration: CMTime
    var info: MediaPeriodInfo

    let mediaSourceList: MediaSourceList
    let trackSelector: TrackSelector

    var trackGroups: TrackGroupArray = .empty
    var prepareCalled: Bool = false
    var isPrepared: Bool = false
    var hasEnabledTracks: Bool = false

    var next: MediaPeriodHolder?

    private var mayRetainStreamFlags: [Bool]

    // TODO: ONE LOCK
    @UnfairLocked private var durationForPlaybackTriggers: DurationTriggers?
    @UnfairLocked private var durationForStartLoadingTriggers: DurationTriggers?
    @UnfairLocked private var durationToStopLoadingTriggers: DurationTriggers?

    init(
        queue: Queue,
        rendererCapabilities: [RendererCapabilitiesResolver],
        rendererPositionOffset: CMTime,
        trackSelector: TrackSelector,
        allocator: Allocator,
        mediaSourceList: MediaSourceList,
        info: MediaPeriodInfo,
        emptyTrackSelectorResult: TrackSelectorResult,
        targetPreloadBufferDuration: CMTime
    ) throws {
        self.queue = queue
        self.rendererCapabilities = rendererCapabilities
        self.renderPositionOffset = rendererPositionOffset
        self.sampleStreams = Array(repeating: nil, count: rendererCapabilities.count)
        self.targetPreloadBufferDuration = targetPreloadBufferDuration
        self.mayRetainStreamFlags = Array(repeating: false, count: rendererCapabilities.count)
        self.mediaSourceList = mediaSourceList
        self.info = info
        self.id = info.id.periodId
        self.trackSelector = trackSelector
        self.trackSelectorResults = emptyTrackSelectorResult

        self.mediaPeriod = try! Self.createMediaPeriod(
            id: info.id,
            mediaSourceList: mediaSourceList,
            allocator: allocator,
            startPosition: info.startPosition,
            endPosition: info.endPosition
        )
    }

    func toRendererTime(periodTime: CMTime) -> CMTime {
        periodTime + renderPositionOffset
    }

    func toPeriodTime(rendererTime: CMTime) -> CMTime {
        return rendererTime - renderPositionOffset
    }

    func getStartPositionRendererTime() -> CMTime {
        info.startPosition + renderPositionOffset
    }

    func isFullyBuffered() -> Bool {
        return isPrepared && (!hasEnabledTracks || mediaPeriod.getBufferedPosition().isPositiveInfinity )
    }

    func isFullyPreloaded() -> Bool {
        return isPrepared &&
            isFullyBuffered() || getBufferedPosition() - info.startPosition >= targetPreloadBufferDuration
    }

    func getBufferedPosition() -> CMTime {
        guard isPrepared else { return info.startPosition }

        let bufferedPosition = hasEnabledTracks ? mediaPeriod.getBufferedPosition() : .positiveInfinity
        return bufferedPosition.isPositiveInfinity ? info.duration : bufferedPosition
    }

    func getNextLoadPosition() -> CMTime {
        !isPrepared ? .zero : mediaPeriod.getNextLoadPosition()
    }

    /// Calls `body` once every stream has at least `duration` buffered ahead, once per install.
    /// While the decoder catches up after a seek, the renderers take samples in bursts and the
    /// buffer crosses `duration` again and again; the player needs waking only the first time.
    func changeDurationForPlaybackTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        durationForPlaybackTriggers = updateTriggers(
            durationForPlaybackTriggers,
            duration: duration,
            condition: { .whenDurationBecomesGreaterThanOrEqualTo($0) },
            fire: { [weak self] in
                guard let self, let triggers = durationForPlaybackTriggers, !triggers.didFire, triggers.allHold else { return }
                durationForPlaybackTriggers?.didFire = true
                body?(self)
            }
        )
    }

    /// Calls `body` when any stream drops below `duration` buffered ahead.
    func changeDurationForStartLoadingTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        durationForStartLoadingTriggers = updateTriggers(
            durationForStartLoadingTriggers,
            duration: duration,
            condition: { .whenDurationBecomesLessThan($0) },
            fire: { [weak self] in
                guard let self, durationForStartLoadingTriggers != nil else { return }
                body?(self)
            }
        )
    }

    /// Calls `body` once every stream has at least `duration` buffered ahead.
    func changeDurationToStopLoadingTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        durationToStopLoadingTriggers = updateTriggers(
            durationToStopLoadingTriggers,
            duration: duration,
            condition: { .whenDurationBecomesGreaterThanOrEqualTo($0) },
            fire: { [weak self] in
                guard let self, durationToStopLoadingTriggers?.allHold == true else { return }
                body?(self)
            }
        )
    }

    /// Installs a trigger for `condition(duration)` on every sample stream; `nil` removes them.
    ///
    /// Triggers already installed for the same duration on the same streams are kept: a fresh
    /// install fires at once when the condition already holds, so reinstalling on every update
    /// would keep waking the player.
    private func updateTriggers(
        _ installed: DurationTriggers?,
        duration: CMTime?,
        condition: (CMTime) -> TriggerCondition,
        fire: @escaping () -> Void
    ) -> DurationTriggers? {
        let streams = sampleStreams.compactMap { $0 }
        if let installed, installed.duration == duration, installed.isInstalled(on: streams) {
            return installed
        }

        installed?.tokens.forEach { $0.stream.removeTrigger($0.token) }
        guard let duration, isPrepared else { return nil }

        let tokens = streams.map { stream -> (stream: SampleStream, token: QueueTriggerToken) in
            let token = stream.installTrigger(condition: condition(duration)) { [queue] _ in
                // Checked on the queue: a condition that already holds fires during this install,
                // before the new tokens are stored.
                queue.justDispatch { fire() }
            }
            return (stream: stream, token: token)
        }

        return DurationTriggers(duration: duration, tokens: tokens)
    }

    func handlePrepared(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) throws {
        assert(queue.isCurrent())
        isPrepared = true
        trackGroups = mediaPeriod.trackGroups
        let selectorResult = try selectTracks(
            playbackSpeed: playbackSpeed,
            timeline: timeline,
            playWhenReady: playWhenReady
        )
        var requestedStartPosition = info.startPosition
        if info.duration.isValid && requestedStartPosition >= info.duration {
            // TODO: check requestedStartPosition = max(.zero, CMTime(value: info.duration.value - 1, timescale: info.duration.timescale))
            requestedStartPosition = max(.zero, info.duration)
        }
        let newStartPosition = try applyTrackSelection(trackSelectorResult: selectorResult,
                                                       position: requestedStartPosition,
                                                       forceRecreateStreams: false)
        renderPositionOffset = renderPositionOffset + info.startPosition - newStartPosition
        info = info.copyWithStartPosition(newStartPosition)
    }

    func reevaluateBuffer(rendererPosition: CMTime) {
        if isPrepared {
            mediaPeriod.reevaluateBuffer(position: toPeriodTime(rendererTime: rendererPosition))
        }
    }

    func continueLoading(loadingInfo: LoadingInfo) {
        mediaPeriod.continueLoading(with: loadingInfo)
    }

    func selectTracks(playbackSpeed: Float, timeline: Timeline, playWhenReady: Bool) throws -> TrackSelectorResult {
        let selectorResult = try trackSelector.selectTracks(
            rendererCapabilities: rendererCapabilities,
            trackGroups: trackGroups,
            periodId: info.id,
            timeline: timeline
        )
        return selectorResult
    }

    @discardableResult
    func applyTrackSelection(
        trackSelectorResult: TrackSelectorResult,
        position: CMTime,
        forceRecreateStreams: Bool
    ) throws -> CMTime {
        assert(queue.isCurrent())
        var streamResetFlags = Array(repeating: false, count: rendererCapabilities.count)
        return try applyTrackSelection(
            newTrackSelectorResult: trackSelectorResult,
            position: position,
            forceRecreateStreams: forceRecreateStreams,
            streamResetFlags: &streamResetFlags
        )
    }

    func applyTrackSelection(
        newTrackSelectorResult: TrackSelectorResult,
        position: CMTime,
        forceRecreateStreams: Bool,
        streamResetFlags: inout [Bool]
    ) throws -> CMTime {
        for index in 0..<newTrackSelectorResult.selections.count {
            mayRetainStreamFlags[index] = !forceRecreateStreams
                && trackSelectorResults == newTrackSelectorResult
        }

        disassociateNoSampleRenderersWithEmptySampleStream(sampleStreams: &sampleStreams)
        disableTrackSelectionsInResult()
        self.trackSelectorResults = newTrackSelectorResult
        enableTrackSelectionsInResult()

        let position = try mediaPeriod.selectTrack(
            selections: newTrackSelectorResult.selections,
            mayRetainStreamFlags: mayRetainStreamFlags,
            streams: &sampleStreams,
            streamResetFlags: &streamResetFlags,
            position: position
        )
        associateNoSampleRenderersWithEmptySampleStream(sampleStreams: &sampleStreams)
        hasEnabledTracks = false
        for (index, sampleStream) in sampleStreams.enumerated() {
            if sampleStream != nil, trackSelectorResults.isRendererEnabled(for: index) {
                if rendererCapabilities[index].trackType != .none {
                    hasEnabledTracks = true
                }
            } else {
                assert(newTrackSelectorResult.selections[index] == nil)
            }
        }

        return position
    }

    func release() {
        [durationForPlaybackTriggers, durationForStartLoadingTriggers, durationToStopLoadingTriggers]
            .compactMap { $0 }
            .forEach { $0.tokens.forEach { $0.stream.removeTrigger($0.token) } }

        disableTrackSelectionsInResult()
        releaseMediaPeriod(mediaSourceList: mediaSourceList, mediaPeriod: mediaPeriod)
    }

    /// `nil` unlinks the rest of the queue; without it, released holders stay reachable.
    func setNext(_ mediaPeriodHolder: MediaPeriodHolder?) {
        guard mediaPeriodHolder !== next else { return }

        disableTrackSelectionsInResult()
        next = mediaPeriodHolder
        enableTrackSelectionsInResult()
    }

    func canBeUsedFor(mediaPeriodInfo: MediaPeriodInfo) -> Bool {
        Self.durationsCompatible(lhs: self.info.duration, rhs: mediaPeriodInfo.duration)
            && self.info.startPosition == mediaPeriodInfo.startPosition
            && self.info.id == mediaPeriodInfo.id
    }

    func prepare(callback: any MediaPeriodCallback, on time: CMTime) {
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
            if rendererEnabled, let selection {
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
        startPosition: CMTime,
        endPosition: CMTime
    ) throws -> MediaPeriod {
        let mediaPeriod = try! mediaSourceList.createPeriod(
            id: id,
            allocator: allocator,
            startPosition: startPosition
        )

        if endPosition.isValid {
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
    static func durationsCompatible(lhs: CMTime, rhs: CMTime) -> Bool {
        !lhs.isValid || lhs == rhs
    }
}

private extension TriggerCondition {
    func isEqual(_ other: TriggerCondition) -> Bool {
        switch (self, other) {
        case (let .whenDurationBecomesLessThan(lhs), let .whenDurationBecomesLessThan(rhs)):
            return lhs == rhs
        case (let .whenDurationBecomesLessThanOrEqualTo(lhs), let .whenDurationBecomesLessThanOrEqualTo(rhs)):
            return lhs == rhs
        case (let .whenDurationBecomesGreaterThan(lhs), let .whenDurationBecomesGreaterThan(rhs)):
            return lhs == rhs
        case (let .whenDurationBecomesGreaterThanOrEqualTo(lhs), let .whenDurationBecomesGreaterThanOrEqualTo(rhs)):
            return lhs == rhs
        case (.whenMinPresentationTimeStampChanges, .whenMinPresentationTimeStampChanges):
            return true
        case (.whenMaxPresentationTimeStampChanges, .whenMaxPresentationTimeStampChanges):
            return true
        case (.whenDataBecomesReady, .whenDataBecomesReady):
            return true
        case (.whenEndOfDataReached, .whenEndOfDataReached):
            return true
        case (.whenReset, .whenReset):
            return true
        case (let .whenBufferCountBecomesLessThan(lhs), let .whenBufferCountBecomesLessThan(rhs)):
            return lhs == rhs
        case (let .whenBufferCountBecomesGreaterThan(lhs), let .whenBufferCountBecomesGreaterThan(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

/// Duration triggers installed on a period's sample streams.
private struct DurationTriggers {
    let duration: CMTime
    let tokens: [(stream: SampleStream, token: QueueTriggerToken)]
    var didFire = false

    /// Whether the condition holds on every stream.
    var allHold: Bool {
        tokens.allSatisfy { $0.stream.testTrigger($0.token) }
    }

    func isInstalled(on streams: [SampleStream]) -> Bool {
        tokens.map { ObjectIdentifier($0.stream) } == streams.map { ObjectIdentifier($0) }
    }
}
