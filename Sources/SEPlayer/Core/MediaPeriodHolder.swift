//
//  MediaPeriodHolder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.MediaPeriodHolder
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
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
        bufferedBytesCounter: BufferedBytesCounter,
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

        self.mediaPeriod = try Self.createMediaPeriod(
            id: info.id,
            mediaSourceList: mediaSourceList,
            bufferedBytesCounter: bufferedBytesCounter,
            startPosition: info.startPosition,
            endPosition: info.endPosition
        )
    }

    func toRendererTime(periodTime: CMTime) -> CMTime {
        periodTime + renderPositionOffset
    }

    func toPeriodTime(rendererTime: CMTime) -> CMTime {
        rendererTime - renderPositionOffset
    }

    func getStartPositionRendererTime() -> CMTime {
        info.startPosition + renderPositionOffset
    }

    func isFullyBuffered() -> Bool {
        isPrepared && (!hasEnabledTracks || mediaPeriod.getBufferedPosition().isPositiveInfinity)
    }

    func isFullyPreloaded() -> Bool {
        isPrepared &&
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

    /// Calls `body` once every stream of `streamIndices` holds media up to `position`, once per install. What the
    /// streams hold ahead of their reads would do for the renderers, but they read ahead: while they take the samples
    /// as they come, it stays short of what the player waits for.
    func changeBufferedPositionForPlaybackTriggerTokens(
        _ position: CMTime?,
        streamIndices: Set<Int>? = nil,
        body: ((MediaPeriodHolder) -> Void)? = nil
    ) {
        // Streams can hold media past the position from before a seek, and fire at once; once they reset, the
        // trigger fires again when they get there.
        if let installed = durationForPlaybackTriggers, installed.didFire, installed.duration == position, !installed.allHold {
            durationForPlaybackTriggers?.didFire = false
        }
        durationForPlaybackTriggers = updateTriggers(
            durationForPlaybackTriggers,
            duration: position,
            streamIndices: streamIndices,
            condition: { .whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo($0) },
            fire: { [weak self] in
                guard let self, let triggers = durationForPlaybackTriggers, !triggers.didFire, triggers.allHold else {
                    return
                }
                durationForPlaybackTriggers?.didFire = true
                body?(self)
            }
        )
    }

    /// Calls `body` when any stream of `streamIndices` drops below `duration` buffered ahead.
    func changeDurationForStartLoadingTriggerTokens(
        _ duration: CMTime?,
        streamIndices: Set<Int>? = nil,
        body: ((MediaPeriodHolder) -> Void)? = nil
    ) {
        durationForStartLoadingTriggers = updateTriggers(
            durationForStartLoadingTriggers,
            duration: duration,
            streamIndices: streamIndices,
            condition: { .whenDurationBecomesLessThan($0) },
            fire: { [weak self] in
                guard let self, durationForStartLoadingTriggers != nil else {
                    return
                }
                body?(self)
            }
        )
    }

    /// Calls `body` once every stream of `streamIndices` has at least `duration` buffered ahead.
    func changeDurationToStopLoadingTriggerTokens(
        _ duration: CMTime?,
        streamIndices: Set<Int>? = nil,
        body: ((MediaPeriodHolder) -> Void)? = nil
    ) {
        durationToStopLoadingTriggers = updateTriggers(
            durationToStopLoadingTriggers,
            duration: duration,
            streamIndices: streamIndices,
            condition: { .whenDurationBecomesGreaterThanOrEqualTo($0) },
            fire: { [weak self] in
                guard let self, durationToStopLoadingTriggers?.allHold == true else {
                    return
                }
                body?(self)
            }
        )
    }

    /// The least any stream of `streamIndices` has queued ahead, or `nil` without such streams.
    func queuedAheadDuration(streamIndices: Set<Int>? = nil) -> CMTime? {
        triggerStreams(streamIndices).map(\.bufferedAheadDuration).filter(\.isNumeric).min()
    }

    /// The streams with media, of `streamIndices`, or all of them when `streamIndices` names none of those.
    private func triggerStreams(_ streamIndices: Set<Int>?) -> [SampleStream] {
        let streams = sampleStreams.indices.compactMap { index -> (index: Int, stream: SampleStream)? in
            guard let stream = sampleStreams[index], !(stream is EmptySampleStream) else {
                return nil
            }
            return (index, stream)
        }
        let selected = streams.filter { streamIndices?.contains($0.index) ?? true }
        return (selected.isEmpty ? streams : selected).map(\.stream)
    }

    /// Installs a trigger for `condition(duration)` on the sample streams of `streamIndices`, or all of them; `nil`
    /// removes them. Streams without media never buffer anything, so they are left out.
    ///
    /// Triggers already installed for the same duration on the same streams are kept: a fresh
    /// install fires at once when the condition already holds, so reinstalling on every update
    /// would keep waking the player.
    private func updateTriggers(
        _ installed: DurationTriggers?,
        duration: CMTime?,
        streamIndices: Set<Int>? = nil,
        condition: (CMTime) -> TriggerCondition,
        fire: @escaping () -> Void
    ) -> DurationTriggers? {
        let streams = triggerStreams(streamIndices)
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
        let newStartPosition = try applyTrackSelection(
            trackSelectorResult: selectorResult,
            position: requestedStartPosition,
            forceRecreateStreams: false
        )
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
        try trackSelector.selectTracks(
            rendererCapabilities: rendererCapabilities,
            trackGroups: trackGroups,
            periodId: info.id,
            timeline: timeline
        )
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
        for index in 0 ..< newTrackSelectorResult.selections.count {
            // Per renderer: the streams of the renderers whose selection didn't change keep playing. Where the media
            // period allows, so do the streams of a new selection of the same group: their buffer is replaced
            // instead, and the renderer keeps showing what it has.
            mayRetainStreamFlags[index] = !forceRecreateStreams
                && (newTrackSelectorResult.isEquivalent(to: trackSelectorResults, at: index)
                    || (mediaPeriod.keepsStreamsForSelectionsInSameGroup
                        && Self.selectsSameGroup(newTrackSelectorResult, trackSelectorResults, at: index)))
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

    /// Takes `newTrackSelectorResult` without touching what is buffered: the streams stay, and only what loads from
    /// now on follows the new selections.
    ///
    /// - Returns: `false` if the new selections can't be taken that way, as when a renderer changes track group;
    ///   nothing changed then.
    func updateTrackSelectionKeepingBuffer(_ newTrackSelectorResult: TrackSelectorResult) -> Bool {
        assert(queue.isCurrent())
        let selections = newTrackSelectorResult.selections
        guard selections.count == trackSelectorResults.selections.count else {
            return false
        }
        for index in selections.indices {
            let isSame = newTrackSelectorResult.isEquivalent(to: trackSelectorResults, at: index)
            guard isSame || Self.selectsSameGroup(newTrackSelectorResult, trackSelectorResults, at: index) else {
                return false
            }
        }

        // Renderers without a selection may read a placeholder stream: it isn't the media period's.
        let streams = sampleStreams.indices.map { selections[$0] == nil ? nil : sampleStreams[$0] }
        guard mediaPeriod.updateSelectionsKeepingBuffer(selections, streams: streams) else {
            return false
        }

        disableTrackSelectionsInResult()
        trackSelectorResults = newTrackSelectorResult
        enableTrackSelectionsInResult()
        return true
    }

    /// Whether both results select from the same track group for the renderer, with the same configuration.
    private static func selectsSameGroup(_ lhs: TrackSelectorResult, _ rhs: TrackSelectorResult, at index: Int) -> Bool {
        guard index < lhs.selections.count, index < rhs.selections.count,
              lhs.rendererConfigurations[index] == rhs.rendererConfigurations[index],
              let lhsSelection = lhs.selections[index], let rhsSelection = rhs.selections[index] else {
            return false
        }
        return lhsSelection.trackGroup == rhsSelection.trackGroup
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
        bufferedBytesCounter: BufferedBytesCounter,
        startPosition: CMTime,
        endPosition: CMTime
    ) throws -> MediaPeriod {
        let mediaPeriod = try mediaSourceList.createPeriod(
            id: id,
            bufferedBytesCounter: bufferedBytesCounter,
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
        lhs === rhs
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
        case let (.whenDurationBecomesLessThan(lhs), .whenDurationBecomesLessThan(rhs)):
            lhs == rhs
        case let (.whenDurationBecomesLessThanOrEqualTo(lhs), .whenDurationBecomesLessThanOrEqualTo(rhs)):
            lhs == rhs
        case let (.whenDurationBecomesGreaterThan(lhs), .whenDurationBecomesGreaterThan(rhs)):
            lhs == rhs
        case let (.whenDurationBecomesGreaterThanOrEqualTo(lhs), .whenDurationBecomesGreaterThanOrEqualTo(rhs)):
            lhs == rhs
        case (.whenMinPresentationTimeStampChanges, .whenMinPresentationTimeStampChanges):
            true
        case (.whenMaxPresentationTimeStampChanges, .whenMaxPresentationTimeStampChanges):
            true
        case let (
            .whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo(lhs),
            .whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo(rhs)
        ):
            lhs == rhs
        case (.whenDataBecomesReady, .whenDataBecomesReady):
            true
        case (.whenEndOfDataReached, .whenEndOfDataReached):
            true
        case (.whenReset, .whenReset):
            true
        case let (.whenBufferCountBecomesLessThan(lhs), .whenBufferCountBecomesLessThan(rhs)):
            lhs == rhs
        case let (.whenBufferCountBecomesGreaterThan(lhs), .whenBufferCountBecomesGreaterThan(rhs)):
            lhs == rhs
        default:
            false
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
