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

    var sampleStreams: [TriggerableSampleStream?]
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
            requestedStartPosition = max(.zero, CMTime(value: info.duration.value - 1, timescale: info.duration.timescale))
        }
        let newStartPosition = applyTrackSelection(trackSelectorResult: selectorResult,
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
    ) -> CMTime {
        assert(queue.isCurrent())
        var streamResetFlags = Array(repeating: false, count: rendererCapabilities.count)
        return applyTrackSelection(
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
    ) -> CMTime {
        for index in 0..<newTrackSelectorResult.selections.count {
            mayRetainStreamFlags[index] = !forceRecreateStreams
                && trackSelectorResults == newTrackSelectorResult
        }

        disassociateNoSampleRenderersWithEmptySampleStream(sampleStreams: &sampleStreams)
        disableTrackSelectionsInResult()
        self.trackSelectorResults = newTrackSelectorResult
        enableTrackSelectionsInResult()

        let position = mediaPeriod.selectTrack(
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

    func disassociateNoSampleRenderersWithEmptySampleStream(sampleStreams: inout [TriggerableSampleStream?]) {
        for (index, capability) in rendererCapabilities.enumerated() {
            if capability.trackType == .unknown {
                sampleStreams[index] = nil
            }
        }
    }

    func associateNoSampleRenderersWithEmptySampleStream(sampleStreams: inout [TriggerableSampleStream?]) {
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
