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
    @UnfairLocked private var durationForPlaybackTriggerTokens: [(SampleStream, QueueTriggerToken)]?
    @UnfairLocked private var durationForStartLoadingTriggerTokens: [(SampleStream, QueueTriggerToken)]?
    @UnfairLocked private var durationToStopLoadingTriggerTokens: [(SampleStream, QueueTriggerToken)]?

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

    func changeDurationForPlaybackTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        let condition: TriggerCondition? = if let duration {
            .whenDurationBecomesGreaterThanOrEqualTo(duration)
        } else {
            nil
        }

        durationForPlaybackTriggerTokens = installTriggers(
            previousTokens: durationForPlaybackTriggerTokens,
            condition: condition,
            body: { [weak self] _ in
                guard let self,
                      let tokens = self.durationForPlaybackTriggerTokens else {
                    return
                }

                queue.justDispatch {
                    if tokens.allSatisfy({ $0.0.testTrigger($0.1) }) {
                        body?(self)
                    }
                }
            }
        )
    }

    func changeDurationForStartLoadingTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        let condition: TriggerCondition? = if let duration {
            .whenDurationBecomesLessThanOrEqualTo(duration)
        } else {
            nil
        }

        durationForStartLoadingTriggerTokens = installTriggers(
            previousTokens: durationForStartLoadingTriggerTokens,
            condition: condition,
            body: { [weak self] _ in
                guard let self else { return }

                body?(self)
            }
        )
    }

    func changeDurationToStopLoadingTriggerTokens(_ duration: CMTime?, body: ((MediaPeriodHolder) -> Void)? = nil) {
        let condition: TriggerCondition? = if let duration {
            .whenDurationBecomesGreaterThanOrEqualTo(duration)
        } else {
            nil
        }

        durationToStopLoadingTriggerTokens = installTriggers(
            previousTokens: durationToStopLoadingTriggerTokens,
            condition: condition,
            body: { [weak self] _ in
                guard let self,
                      let tokens = self.durationToStopLoadingTriggerTokens else {
                    return
                }

                queue.justDispatch {
                    if tokens.allSatisfy({ $0.0.testTrigger($0.1) }) {
                        body?(self)
                    }
                }
            }
        )
    }

    private func installTriggers(
        previousTokens: [(SampleStream, QueueTriggerToken)]?,
        condition: TriggerCondition?,
        body: @escaping (QueueTriggerToken) -> Void
    ) -> [(SampleStream, QueueTriggerToken)]? {
        if let previousTokens {
            previousTokens.forEach { stream, token in
                stream.removeTrigger(token)
            }
        }

        guard let condition, isPrepared else { return nil }

        return sampleStreams
            .compactMap { $0 }
            .map { stream in
                let token = stream.installTrigger(condition: condition) { token in
                    body(token)
                }

                return (stream, token)
            }
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
        durationForPlaybackTriggerTokens?.forEach { $0.0.removeTrigger($0.1) }
        durationForStartLoadingTriggerTokens?.forEach { $0.0.removeTrigger($0.1) }
        durationToStopLoadingTriggerTokens?.forEach { $0.0.removeTrigger($0.1) }

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
        Self.durationsCompatible(lhs: self.info.duration, rhs: mediaPeriodInfo.duration)
            && self.info.startPosition == info.startPosition
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
