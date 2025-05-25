//
//  MediaPeriodQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import Foundation.NSUUID

final class MediaPeriodQueue {
    var playing: MediaPeriodHolder?
    var reading: MediaPeriodHolder?
    var prewarming: MediaPeriodHolder?
    var loading: MediaPeriodHolder?
    var preloading: MediaPeriodHolder?

    private var period: Period
    private var window: Window
    private let builder: (MediaPeriodInfo, Int64) throws -> MediaPeriodHolder

    private var nextWindowSequenceNumber: Int = 0
    private var repeatMode: SEPlayer.RepeatMode = .off
    private var shuffleModeEnabled: Bool = false
    private var preloadConfiguration: PreloadConfiguration
    private var count: Int = 0
    private var oldFrontPeriodUUID: UUID?
    private var oldFrontPeriodWindowSequenceNumber: Int = 0
    private var preloadPriorityList: [MediaPeriodHolder] = []

    init(
        mediaPeriodBuilder: @escaping (MediaPeriodInfo, Int64) throws -> MediaPeriodHolder,
        preloadConfiguration: PreloadConfiguration = .default
    ) {
        period = Period()
        window = Window()
        builder = mediaPeriodBuilder
        self.preloadConfiguration = preloadConfiguration
    }

    func updateRepeatMode(new repeatMode: SEPlayer.RepeatMode, timeline: Timeline) -> UpdatePeriodQueueResult {
        self.repeatMode = repeatMode
        return updateForPlaybackModeChange(with: timeline)
    }

    func updateShuffleMode(new shuffleModeEnabled: Bool, timeline: Timeline) -> UpdatePeriodQueueResult {
        self.shuffleModeEnabled = shuffleModeEnabled
        return updateForPlaybackModeChange(with: timeline)
    }

    func updatePreloadConfiguration(new preloadConfiguration: PreloadConfiguration, timeline: Timeline) throws {
        self.preloadConfiguration = preloadConfiguration
        try invalidatePreloadPool(timeline: timeline)
    }

    func isLoading(mediaPeriod: any MediaPeriod) -> Bool {
        loading != nil && loading?.mediaPeriod === mediaPeriod
    }

    func isPreloading(mediaPeriod: any MediaPeriod) -> Bool {
        preloading != nil && loading?.mediaPeriod === mediaPeriod
    }

    func reevaluateBuffer(rendererPositionUs: Int64) {
        loading?.reevaluateBuffer(rendererPosition: rendererPositionUs)
    }

    func shouldLoadNextMediaPeriod() -> Bool {
        guard let loading else { return true }
        return loading.info.isFinal
        && loading.isFullyBuffered()
        && loading.info.durationUs != .timeUnset
        && preloadPriorityList.count < Self.maximumBufferAheadPeriods
    }

    func nextMediaPeriodInfo(rendererPositionUs: Int64, playbackInfo: PlaybackInfo) -> MediaPeriodInfo? {
        if let loading {
            return followingMediaPeriodInfo(
                timeline: playbackInfo.timeline,
                mediaPeriodHolder: loading,
                rendererPositionUs: rendererPositionUs
            )
        } else {
            return firstMediaPeriodInfo(with: playbackInfo)
        }
    }

    func enqueueNextMediaPeriodHolder(info: MediaPeriodInfo) throws -> MediaPeriodHolder {
        let rendererPositionOffsetUs = if let loading {
            loading.renderPositionOffset + loading.info.durationUs - info.startPositionUs
        } else {
            Self.initialRendererPositionOffsetUs
        }
        
        let newPeriodHolder = try removePreloadedMediaPeriodHolder(info: info) ?? builder(info, rendererPositionOffsetUs)
        newPeriodHolder.info = info
        newPeriodHolder.renderPositionOffset = rendererPositionOffsetUs
        
        if let loading {
            loading.setNext(newPeriodHolder)
        } else {
            playing = newPeriodHolder
            reading = newPeriodHolder
            prewarming = newPeriodHolder
        }
        oldFrontPeriodUUID = nil
        loading = newPeriodHolder
        count += 1
        notifyQueueUpdate()
        return newPeriodHolder
    }

    func invalidatePreloadPool(timeline: Timeline) throws {
        guard preloadConfiguration.targetPreloadDurationUs == .timeUnset || loading != nil else {
            releasePreloadPool()
            return
        }
        guard let loading else { return }

        var newPreloadPriorityList = [MediaPeriodHolder]()
        let defaultPositionOfNextWindow = defaultPeriodPositionOfNextWindow(timeline: timeline,
                                                                            periodId: loading.info.id.periodId,
                                                                            defaultPositionProjectionUs: .zero)
        if let defaultPositionOfNextWindow {
            let windowSequenceNumber: Int
            if let sequenceNumber = resolvePeriodUUIDToWindowSequenceNumberInPreloadPeriods(periodId: defaultPositionOfNextWindow.0) {
                windowSequenceNumber = sequenceNumber
            } else {
                nextWindowSequenceNumber += 1
                windowSequenceNumber = nextWindowSequenceNumber
            }

            let nextInfo = mediaPeriodInfoForPeriodPosition(timeline: timeline,
                                                            periodId: defaultPositionOfNextWindow.0,
                                                            positionUs: defaultPositionOfNextWindow.1,
                                                            windowSequenceNumber: windowSequenceNumber)

            let nextMediaPeriodHolder: MediaPeriodHolder
            if let next = removePreloadedMediaPeriodHolder(info: nextInfo) {
                nextMediaPeriodHolder = next
            } else {
                let rendererPositionOffsetUs = loading.renderPositionOffset + loading.info.durationUs - nextInfo.startPositionUs
                nextMediaPeriodHolder = try builder(nextInfo, rendererPositionOffsetUs)
            }
            newPreloadPriorityList.append(nextMediaPeriodHolder)
        }

        releaseAndResetPreloadPriorityList(new: newPreloadPriorityList)
    }

    func releasePreloadPool() {
        guard !preloadPriorityList.isEmpty else { return }
        releaseAndResetPreloadPriorityList(new: [])
    }

    private func removePreloadedMediaPeriodHolder(info: MediaPeriodInfo) -> MediaPeriodHolder? {
        for (index, mediaPeriodHolder) in preloadPriorityList.enumerated() {
            if mediaPeriodHolder.canBeUsedFor(mediaPeriodInfo: info) {
                return preloadPriorityList.remove(at: index)
            }
        }

        return nil
    }

    private func releaseAndResetPreloadPriorityList(new priorityList: [MediaPeriodHolder]) {
        preloadPriorityList.forEach { $0.release() }
        preloadPriorityList = priorityList
        preloading = nil
        maybeUpdatePreloadMediaPeriodHolder()
    }

    private func mediaPeriodInfoForPeriodPosition(
        timeline: Timeline,
        periodId: AnyHashable,
        positionUs: Int64,
        windowSequenceNumber: Int
    ) -> MediaPeriodInfo {
        mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: periodId,
            startPositionUs: positionUs,
            requestedContentPositionUs: .timeUnset,
            windowSequenceNumber: windowSequenceNumber
        )
    }

    private func defaultPeriodPositionOfNextWindow(
        timeline: Timeline,
        periodId: AnyHashable,
        defaultPositionProjectionUs: Int64
    ) -> (AnyHashable, Int64)? {
        let nextWindowIndex = timeline.nextWindowIndex(
            windowIndex: timeline.periodById(periodId, period: &period).windowIndex,
            repeatMode: repeatMode,
            shuffleModeEnabled: shuffleModeEnabled
        )

        if let nextWindowIndex {
            return timeline.periodPositionUs(
                window: &window,
                period: &period,
                windowIndex: nextWindowIndex,
                windowPositionUs: .timeUnset,
                defaultPositionProjectionUs: defaultPositionProjectionUs
            )
        } else {
            return nil
        }
    }

    func advanceReadingPeriod() -> MediaPeriodHolder? {
        if prewarming == reading {
            prewarming = reading?.next
        }

        reading = reading?.next
        notifyQueueUpdate()
        return reading
    }

    func advancePrewarmingPeriod() -> MediaPeriodHolder? {
        prewarming = prewarming?.next
        notifyQueueUpdate()
        return prewarming
    }

    func advancePlayingPeriod() -> MediaPeriodHolder? {
        guard let playing else { return nil }

        if playing == reading {
            reading = playing.next
        }

        if playing == prewarming {
            prewarming = playing.next
        }
        playing.release()
        count -= 1

        if count == 0 {
            loading = nil
            // TODO: oldFrontPeriod
        }
        self.playing = playing.next
        notifyQueueUpdate()
        return self.playing
    }

    @discardableResult
    func removeAfter(mediaPeriodHolder: MediaPeriodHolder) -> UpdatePeriodQueueResult {
        guard mediaPeriodHolder != loading else { return .init() }

        var removedResult = UpdatePeriodQueueResult()
        var mediaPeriodHolder = mediaPeriodHolder
        loading = mediaPeriodHolder

        while let next = mediaPeriodHolder.next {
            mediaPeriodHolder = next
            if mediaPeriodHolder == reading {
                reading = playing
                prewarming = playing
                removedResult = [.alteredReadingPeriod, .alteredPrewarmingPeriod]
            }
            if mediaPeriodHolder == prewarming {
                prewarming = reading
                removedResult = [.alteredPrewarmingPeriod]
            }
            mediaPeriodHolder.release()
            count -= 1
        }

        loading?.setNext(nil)
        notifyQueueUpdate()
        return removedResult
    }

    func maybeUpdatePreloadMediaPeriodHolder() {
        guard let preloading, preloading.isFullyPreloaded() else { return }

        self.preloading = nil
        for mediaPeriodHolder in preloadPriorityList {
            if !mediaPeriodHolder.isFullyBuffered() {
                self.preloading = mediaPeriodHolder
                break
            }
        }
    }

    func preloadHolderFor(mediaPeriod: MediaPeriod) -> MediaPeriodHolder? {
        preloadPriorityList.first(where: { $0.mediaPeriod === mediaPeriod })
    }

    func clear() {
        guard count != .zero else { return }

        var front = playing
        if let front {
            // TODO: oldFrontPeriodUid
        }

        while let frontHolder = front {
            frontHolder.release()
            front = frontHolder.next
        }

        playing = nil
        loading = nil
        reading = nil
        prewarming = nil
        count = 0
        notifyQueueUpdate()
    }

    func updateQueuedPeriods(
        timeline: Timeline,
        rendererPositionUs: Int64,
        maxRendererReadPositionUs: Int64,
        maxRendererPrewarmingPositionUs: Int64
    ) -> UpdatePeriodQueueResult {
        var previousPeriodHolder: MediaPeriodHolder?
        var periodHolder = playing

        while let holder = periodHolder {
            let oldPeriodInfo = holder.info
            var newPeriodInfo: MediaPeriodInfo
            if let previousPeriodHolder {
                let periodInfo = followingMediaPeriodInfo(timeline: timeline,
                                                         mediaPeriodHolder: holder,
                                                         rendererPositionUs: rendererPositionUs)
                switch periodInfo {
                case let .some(periodInfo):
                    if !canKeepMediaPeriodHolder(oldInfo: oldPeriodInfo, newInfo: periodInfo) {
                        fallthrough
                    }
                    newPeriodInfo = periodInfo
                case .none:
                    return removeAfter(mediaPeriodHolder: previousPeriodHolder)
                }
            } else {
                newPeriodInfo = updatedMediaPeriodInfo(with: oldPeriodInfo, timeline: timeline)
            }

            holder.info = newPeriodInfo.copyWithStartPositionUs(oldPeriodInfo.requestedContentPositionUs)
            if MediaPeriodHolder.durationsCompatible(lhs: oldPeriodInfo.durationUs, rhs: newPeriodInfo.durationUs) {
                // TODO: periodHolder.updateClipping()
                let newDurationInRendererTime: Int64 = if newPeriodInfo.durationUs == .timeUnset {
                    .max
                } else {
                    holder.toRendererTime(periodTime: newPeriodInfo.durationUs)
                }
                
                let isReadingAndReadBeyondNewDuration = periodHolder == reading &&
                    (maxRendererReadPositionUs == .endOfSource || maxRendererReadPositionUs >= newDurationInRendererTime)

                let isPrewarmingAndReadBeyondNewDuration = periodHolder == prewarming &&
                    (maxRendererPrewarmingPositionUs == .endOfSource || maxRendererPrewarmingPositionUs >= newDurationInRendererTime)

                var removeAfterResult = removeAfter(mediaPeriodHolder: holder)
                if !removeAfterResult.isEmpty { return removeAfterResult }

                if isReadingAndReadBeyondNewDuration {
                    removeAfterResult.insert(.alteredReadingPeriod)
                }
                if isPrewarmingAndReadBeyondNewDuration {
                    removeAfterResult.insert(.alteredPrewarmingPeriod)
                }
                return removeAfterResult
            }

            previousPeriodHolder = holder
            periodHolder = holder.next
        }

        return []
    }

    func updatedMediaPeriodInfo(with info: MediaPeriodInfo, timeline: Timeline) -> MediaPeriodInfo {
        let id = info.id
        let lastInPeriod = isLastInPeriod(id: id)
        let lastInWindow = isLastInWindow(timeline: timeline, id: id)
        let lastInTimeline = isLastInTimeline(timeline, id: id, isLastMediaPeriodInPeriod: lastInPeriod)
        timeline.periodById(id.periodId, period: &period)

        return MediaPeriodInfo(
            id: id,
            startPositionUs: info.startPositionUs,
            requestedContentPositionUs: info.requestedContentPositionUs,
            endPositionUs: .timeUnset,
            durationUs: period.durationUs,
            isLastInTimelinePeriod: lastInPeriod,
            isLastInTimelineWindow: lastInWindow,
            isFinal: lastInTimeline
        )
    }

    private func notifyQueueUpdate() {
        // TODO: collect analytics
    }

    private func resolvePeriodUUIDToWindowSequenceNumberInPreloadPeriods(periodId: AnyHashable) -> Int? {
        preloadPriorityList.first(where: { $0.info.id.periodId == periodId })?.info.id.windowSequenceNumber
    }

    private func canKeepMediaPeriodHolder(oldInfo: MediaPeriodInfo, newInfo: MediaPeriodInfo) -> Bool {
        oldInfo.startPositionUs == newInfo.startPositionUs && oldInfo.id == newInfo.id
    }

    private func updateForPlaybackModeChange(with timeline: Timeline) -> UpdatePeriodQueueResult {
        guard var lastValidPeriodHolder = playing else { return [] }

        var currentPeriodIndex = timeline.indexOfPeriod(by: lastValidPeriodHolder.id)
        while true, let periodIndex = currentPeriodIndex {
            let nextPeriodIndex = timeline.nextPeriodIndex(periodIndex: periodIndex,
                                                           period: &period,
                                                           window: &window,
                                                           repeatMode: repeatMode,
                                                           shuffleModeEnabled: shuffleModeEnabled)

            while let next = lastValidPeriodHolder.next,
                  !lastValidPeriodHolder.info.isLastInTimelinePeriod {
                lastValidPeriodHolder = next
            }

            guard let nextPeriodIndex,
                  let nextMediaPeriodHolder = lastValidPeriodHolder.next else {
                break
            }

            let nextPeriodHolderPeriodIndex = timeline
                .indexOfPeriod(by: nextMediaPeriodHolder.id)
            guard let nextPeriodHolderPeriodIndex, nextPeriodHolderPeriodIndex == nextPeriodIndex else {
                break
            }
            lastValidPeriodHolder = nextMediaPeriodHolder
            currentPeriodIndex = nextPeriodIndex
        }

        let removeAfterResult = removeAfter(mediaPeriodHolder: lastValidPeriodHolder)
        lastValidPeriodHolder.info = updatedMediaPeriodInfo(with: lastValidPeriodHolder.info, timeline: timeline)

        return removeAfterResult
    }

    private func firstMediaPeriodInfo(with playbackInfo: PlaybackInfo) -> MediaPeriodInfo {
        getMediaPeriodInfo(
            timeline: playbackInfo.timeline,
            id: playbackInfo.periodId,
            requestedContentPositionUs: playbackInfo.requestedContentPositionUs,
            startPositionUs: playbackInfo.positionUs
        )
    }

    private func followingMediaPeriodInfo(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        rendererPositionUs: Int64
    ) -> MediaPeriodInfo? {
        let mediaPeriodInfo = mediaPeriodHolder.info
        let bufferedDurationUs = mediaPeriodHolder.renderPositionOffset + mediaPeriodInfo.durationUs - rendererPositionUs

        if mediaPeriodInfo.isLastInTimelinePeriod {
            return firstMediaPeriodInfoOfNextPeriod(
                timeline: timeline,
                mediaPeriodHolder: mediaPeriodHolder,
                bufferedDurationUs: bufferedDurationUs
            )
        } else {
            return followingMediaPeriodInfoOfCurrentPeriod(
                timeline: timeline,
                mediaPeriodHolder: mediaPeriodHolder,
                bufferedDurationUs: bufferedDurationUs
            )
        }
    }

    private func firstMediaPeriodInfoOfNextPeriod(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        bufferedDurationUs: Int64
    ) -> MediaPeriodInfo? {
        let mediaPeriodInfo = mediaPeriodHolder.info
        let currentPeriodIndex = timeline.indexOfPeriod(by: mediaPeriodInfo.id.periodId)

        guard let currentPeriodIndex,
              let nextPeriodIndex = timeline.nextPeriodIndex(periodIndex: currentPeriodIndex,
                                                             period: &period,
                                                             window: &window,
                                                             repeatMode: repeatMode,
                                                             shuffleModeEnabled: shuffleModeEnabled) else {
            return nil
        }

        var startPositionUs = Int64.zero
        var contentPositionUs = Int64.zero

        let nextWindowIndex = timeline.getPeriod(periodIndex: nextPeriodIndex, period: &period, setIds: true).windowIndex
        guard var nextPeriodUUID = period.uuid else { return nil }

        if timeline.getWindow(windowIndex: nextWindowIndex, window: &window).firstPeriodIndex == nextPeriodIndex {
            contentPositionUs = .timeUnset
            guard let defaultPositionUs = timeline.periodPositionUs(window: &window,
                                                                    period: &period,
                                                                    windowIndex: nextWindowIndex,
                                                                    windowPositionUs: .timeUnset,
                                                                    defaultPositionProjectionUs: max(0, bufferedDurationUs)) else {
                return nil
            }

            nextPeriodUUID = defaultPositionUs.0
            startPositionUs = defaultPositionUs.1
        }

        let periodId = MediaPeriodId(periodId: nextPeriodUUID, windowSequenceNumber: nextWindowSequenceNumber)
        return getMediaPeriodInfo(
            timeline: timeline,
            id: periodId,
            requestedContentPositionUs: contentPositionUs,
            startPositionUs: startPositionUs
        )
    }

    private func followingMediaPeriodInfoOfCurrentPeriod(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        bufferedDurationUs: Int64
    ) -> MediaPeriodInfo? {
        let mediaPeriodInfo = mediaPeriodHolder.info
        let currentPeriodId = mediaPeriodInfo.id
        timeline.periodById(currentPeriodId.periodId, period: &period)

        return mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: currentPeriodId.periodId,
            startPositionUs: period.durationUs,
            requestedContentPositionUs: mediaPeriodInfo.durationUs,
            windowSequenceNumber: currentPeriodId.windowSequenceNumber
        )
    }

    private func getMediaPeriodInfo(
        timeline: Timeline,
        id: MediaPeriodId,
        requestedContentPositionUs: Int64,
        startPositionUs: Int64
    ) -> MediaPeriodInfo {
        timeline.periodById(id.periodId, period: &period)

        return mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: id.periodId,
            startPositionUs: startPositionUs,
            requestedContentPositionUs: requestedContentPositionUs,
            windowSequenceNumber: id.windowSequenceNumber
        )
    }

    private func mediaPeriodInfoForContent(
        timeline: Timeline,
        periodId: AnyHashable,
        startPositionUs: Int64,
        requestedContentPositionUs: Int64,
        windowSequenceNumber: Int?
    ) -> MediaPeriodInfo {
        period = timeline.periodById(periodId, period: &period)

        let id = MediaPeriodId(periodId: periodId, windowSequenceNumber: windowSequenceNumber)
        let isLastInPeriod = isLastInPeriod(id: id)
        let isLastInWindow = isLastInWindow(timeline: timeline, id: id)
        let isLastInTimeline = isLastInTimeline(timeline, id: id, isLastMediaPeriodInPeriod: isLastInPeriod)

        return MediaPeriodInfo(
            id: id,
            startPositionUs: max(0, period.durationUs - (isLastInTimeline ? 1 : 0)),
            requestedContentPositionUs: requestedContentPositionUs,
            endPositionUs: .timeUnset,
            durationUs: period.durationUs,
            isLastInTimelinePeriod: isLastInPeriod,
            isLastInTimelineWindow: isLastInWindow,
            isFinal: isLastInTimeline
        )
    }

    private func isLastInPeriod(id: MediaPeriodId) -> Bool {
        // TODO: ads
        return true
    }

    private func isLastInWindow(timeline: Timeline, id: MediaPeriodId) -> Bool {
        guard isLastInPeriod(id: id) else { return false }

        let windowIndex = timeline.periodById(id.periodId, period: &period).windowIndex
        let periodIndex = timeline.indexOfPeriod(by: id.periodId)
        return timeline.getWindow(windowIndex: windowIndex, window: &window).lastPeriodIndex == periodIndex
    }

    private func isLastInTimeline(_ timeline: Timeline, id: MediaPeriodId, isLastMediaPeriodInPeriod: Bool) -> Bool {
        guard let periodIndex = timeline.indexOfPeriod(by: id.periodId) else {
            return true
        }
        let windowIndex = timeline.getPeriod(periodIndex: periodIndex, period: &period).windowIndex
        return isLastMediaPeriodInPeriod && !timeline.getWindow(windowIndex: windowIndex, window: &window).isDynamic
            && timeline.isLastPeriod(
                periodIndex: periodIndex,
                period: &period,
                window: &window,
                repeatMode: repeatMode,
                shuffleModeEnabled: shuffleModeEnabled
            )
        
    }
}

extension MediaPeriodQueue {
    struct UpdatePeriodQueueResult: OptionSet {
        let rawValue: UInt8
        static let alteredReadingPeriod = UpdatePeriodQueueResult(rawValue: 1)
        static let alteredPrewarmingPeriod = UpdatePeriodQueueResult(rawValue: 1 << 1)
    }

    static let initialRendererPositionOffsetUs: Int64 = 1_000_000_000_000
    static let maximumBufferAheadPeriods = 100
}
