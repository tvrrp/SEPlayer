//
//  MediaPeriodQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.01.2025.
//

import CoreMedia
import Foundation.NSUUID
import SEPlayerCommon

final class MediaPeriodQueue {
    var playing: MediaPeriodHolder?
    var reading: MediaPeriodHolder?
    var prewarming: MediaPeriodHolder?
    var loading: MediaPeriodHolder?
    var preloading: MediaPeriodHolder?

    private var period: Period
    private var window: Window
    private var builder: ((MediaPeriodInfo, CMTime) throws -> MediaPeriodHolder)?

    private var nextWindowSequenceNumber: Int = 0
    private var repeatMode: RepeatMode = .off
    private var shuffleModeEnabled: Bool = false
    private var preloadConfiguration: PreloadConfiguration
    private var count: Int = 0
    private var oldFrontPeriodId: AnyHashable?
    private var oldFrontPeriodWindowSequenceNumber: Int = 0
    private var preloadPriorityList: [MediaPeriodHolder] = []

    init(
        mediaPeriodBuilder: ((MediaPeriodInfo, CMTime) throws -> MediaPeriodHolder)? = nil,
        preloadConfiguration: PreloadConfiguration = .default
    ) {
        period = Period()
        window = Window()
        builder = mediaPeriodBuilder
        self.preloadConfiguration = preloadConfiguration
    }

    func setMediaPeriodBuilder(_ builder: @escaping (MediaPeriodInfo, CMTime) throws -> MediaPeriodHolder) {
        self.builder = builder
    }

    func updateRepeatMode(new repeatMode: RepeatMode, timeline: Timeline) -> UpdatePeriodQueueResult {
        self.repeatMode = repeatMode
        return updateForPlaybackModeChange(with: timeline)
    }

    func updateShuffleMode(new shuffleModeEnabled: Bool, timeline: Timeline) -> UpdatePeriodQueueResult {
        self.shuffleModeEnabled = shuffleModeEnabled
        return updateForPlaybackModeChange(with: timeline)
    }

    func updatePreloadConfiguration(new preloadConfiguration: PreloadConfiguration, timeline: Timeline) throws {
        self.preloadConfiguration = preloadConfiguration
        try! invalidatePreloadPool(timeline: timeline)
    }

    func isLoading(mediaPeriod: any MediaPeriod) -> Bool {
        loading != nil && loading?.mediaPeriod === mediaPeriod
    }

    func isPreloading(mediaPeriod: any MediaPeriod) -> Bool {
        preloading != nil && preloading?.mediaPeriod === mediaPeriod
    }

    func reevaluateBuffer(rendererPosition: CMTime) {
        loading?.reevaluateBuffer(rendererPosition: rendererPosition)
    }

    func shouldLoadNextMediaPeriod() -> Bool {
        guard let loading else { return true }
        return !loading.info.isFinal
            && loading.isFullyBuffered()
            && loading.info.duration.isValid
            && count < Self.maximumBufferAheadPeriods
    }

    func nextMediaPeriodInfo(rendererPosition: CMTime, playbackInfo: PlaybackInfo) -> MediaPeriodInfo? {
        if let loading {
            return followingMediaPeriodInfo(
                timeline: playbackInfo.timeline,
                mediaPeriodHolder: loading,
                rendererPosition: rendererPosition
            )
        } else {
            return firstMediaPeriodInfo(with: playbackInfo)
        }
    }

    func enqueueNextMediaPeriodHolder(info: MediaPeriodInfo) throws -> MediaPeriodHolder {
        let rendererPositionOffset = if let loading {
            loading.renderPositionOffset + loading.info.duration - info.startPosition
        } else {
            Self.initialRendererPositionOffset
        }

        let newPeriodHolder: MediaPeriodHolder
        if let periodHolder = removePreloadedMediaPeriodHolder(info: info) {
            newPeriodHolder = periodHolder
            newPeriodHolder.info = info
            newPeriodHolder.renderPositionOffset = rendererPositionOffset
        } else if let builder {
            newPeriodHolder = try builder(info, rendererPositionOffset)
        } else {
            throw ErrorBuilder(errorDescription: "") // TODO: real error
        }

        if let loading {
            loading.setNext(newPeriodHolder)
        } else {
            playing = newPeriodHolder
            reading = newPeriodHolder
            prewarming = newPeriodHolder
        }
        oldFrontPeriodId = nil
        loading = newPeriodHolder
        count += 1
        notifyQueueUpdate()
        return newPeriodHolder
    }

    func invalidatePreloadPool(timeline: Timeline) throws {
        guard preloadConfiguration.targetPreloadDuration.isValid, let loading else {
            releasePreloadPool()
            return
        }

        var newPreloadPriorityList = [MediaPeriodHolder]()
        let defaultPositionOfNextWindow = defaultPeriodPositionOfNextWindow(timeline: timeline,
                                                                            periodId: loading.info.id.periodId,
                                                                            defaultPositionProjection: .zero)
        if let defaultPositionOfNextWindow {
           // TODO: timeline.getWindow(windowIndex: defaultPositionOfNextWindow.0, window: window).isLive {
            let windowSequenceNumber: Int
            if let sequenceNumber = resolvePeriodIdToWindowSequenceNumberInPreloadPeriods(periodId: defaultPositionOfNextWindow.0) {
                windowSequenceNumber = sequenceNumber
            } else {
                windowSequenceNumber = nextWindowSequenceNumber
                nextWindowSequenceNumber += 1
            }

            let nextInfo = mediaPeriodInfoForPeriodPosition(timeline: timeline,
                                                            periodId: defaultPositionOfNextWindow.0,
                                                            position: defaultPositionOfNextWindow.1,
                                                            windowSequenceNumber: windowSequenceNumber)

            let nextMediaPeriodHolder: MediaPeriodHolder
            if let next = removePreloadedMediaPeriodHolder(info: nextInfo) {
                nextMediaPeriodHolder = next
            } else {
                let rendererPositionOffset = loading.renderPositionOffset + loading.info.duration - nextInfo.startPosition
                if let periodHolder = try! builder?(nextInfo, rendererPositionOffset) {
                    nextMediaPeriodHolder = periodHolder
                } else {
                    throw ErrorBuilder(errorDescription: "") // TODO: real error
                }
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
        for index in 0..<preloadPriorityList.count {
            let mediaPeriodHolder = preloadPriorityList[index]
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
        position: CMTime,
        windowSequenceNumber: Int
    ) -> MediaPeriodInfo {
        let mediaPeriodId = resolveMediaPeriodIdForAds(
            timeline: timeline,
            periodId: periodId,
            position: position,
            windowSequenceNumber: windowSequenceNumber,
            window: window,
            period: period
        )
        // TODO: ad check
        return mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: mediaPeriodId.periodId,
            startPosition: position,
            requestedContentPosition: .invalid,
            windowSequenceNumber: windowSequenceNumber,
        )
    }

    private func defaultPeriodPositionOfNextWindow(
        timeline: Timeline,
        periodId: AnyHashable,
        defaultPositionProjection: CMTime
    ) -> (AnyHashable, CMTime)? {
        let nextWindowIndex = timeline.nextWindowIndex(
            windowIndex: timeline.periodById(periodId, period: period).windowIndex,
            repeatMode: repeatMode,
            shuffleModeEnabled: shuffleModeEnabled
        )

        if let nextWindowIndex {
            return timeline.periodPosition(
                window: window,
                period: period,
                windowIndex: nextWindowIndex,
                windowPosition: .invalid,
                defaultPositionProjection: defaultPositionProjection
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

    @discardableResult
    func advancePrewarmingPeriod() -> MediaPeriodHolder? {
        prewarming = prewarming?.next
        notifyQueueUpdate()
        return prewarming
    }

    @discardableResult
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
            oldFrontPeriodId = playing.id
            oldFrontPeriodWindowSequenceNumber = playing.info.id.windowSequenceNumber ?? .zero
        }
        self.playing = playing.next
        notifyQueueUpdate()
        return self.playing
    }

    @discardableResult
    func removeAfter(mediaPeriodHolder: MediaPeriodHolder) -> UpdatePeriodQueueResult {
        guard mediaPeriodHolder != loading else { return [] }

        var removedResult = UpdatePeriodQueueResult()
        loading = mediaPeriodHolder
        var mediaPeriodHolder = mediaPeriodHolder

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
        guard preloading?.isFullyPreloaded() ?? true else {
            return
        }

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
            oldFrontPeriodId = front.id
            oldFrontPeriodWindowSequenceNumber = front.info.id.windowSequenceNumber ?? .zero
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
        rendererPosition: CMTime,
        maxRendererReadPosition: CMTime,
        maxRendererPrewarmingPosition: CMTime
    ) -> UpdatePeriodQueueResult {
        var previousPeriodHolder: MediaPeriodHolder?
        var periodHolder = playing

        while let holder = periodHolder {
            let oldPeriodInfo = holder.info
            var newPeriodInfo: MediaPeriodInfo

            if let previousPeriodHolder {
                let periodInfo = followingMediaPeriodInfo(timeline: timeline,
                                                         mediaPeriodHolder: previousPeriodHolder,
                                                         rendererPosition: rendererPosition)
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

            holder.info = newPeriodInfo.copyWithRequestedContentPosition(oldPeriodInfo.requestedContentPosition)
            if oldPeriodInfo.duration != newPeriodInfo.duration {
                // TODO: periodHolder.updateClipping()
                let newDurationInRendererTime: CMTime = if newPeriodInfo.duration.isValid == false {
                    .positiveInfinity
                } else {
                    holder.toRendererTime(periodTime: newPeriodInfo.duration)
                }

                let isReadingAndReadBeyondNewDuration = periodHolder == reading && // TODO: !periodHolder.info.isFollowedByTransitionToSameStream
                    (maxRendererReadPosition.isPositiveInfinity || maxRendererReadPosition >= newDurationInRendererTime)

                let isPrewarmingAndReadBeyondNewDuration = periodHolder == prewarming &&
                    (maxRendererPrewarmingPosition.isPositiveInfinity || maxRendererPrewarmingPosition >= newDurationInRendererTime)

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
        timeline.periodById(id.periodId, period: period)

        // TODO: ad handling
        return MediaPeriodInfo(
            id: id,
            startPosition: info.startPosition,
            requestedContentPosition: info.requestedContentPosition,
            endPosition: .invalid,
            duration: period.duration,
            isLastInTimelinePeriod: lastInPeriod,
            isLastInTimelineWindow: lastInWindow,
            isFinal: lastInTimeline
        )
    }

    func resolveMediaPeriodIdForAds(
        timeline: Timeline,
        periodId: AnyHashable,
        position: CMTime
    ) -> MediaPeriodId {
        let windowSequenceNumber = resolvePeriodIdToWindowSequenceNumber(period, timeline: timeline)
        return resolveMediaPeriodIdForAds(
            timeline: timeline,
            periodId: periodId,
            position: position,
            windowSequenceNumber: windowSequenceNumber ?? 0,
            window: window,
            period: period
        )
    }

    private func resolveMediaPeriodIdForAds(
        timeline: Timeline,
        periodId: AnyHashable,
        position: CMTime,
        windowSequenceNumber: Int,
        window: Window,
        period: Period
    ) -> MediaPeriodId {
        timeline.periodById(periodId, period: period)
        timeline.getWindow(windowIndex: period.windowIndex, window: window)

        // TODO: ad
        return MediaPeriodId(periodId: periodId, windowSequenceNumber: windowSequenceNumber)
    }

    func resolveMediaPeriodIdForAdsAfterPeriodPositionChange(
        timeline: Timeline, periodId: AnyHashable, position: CMTime
    ) -> MediaPeriodId {
        let windowSequenceNumber = resolvePeriodIdToWindowSequenceNumber(periodId, timeline: timeline) ?? .zero
        timeline.periodById(periodId, period: period)
        timeline.getWindow(windowIndex: period.windowIndex, window: window)

        // TODO: Ad
        return resolveMediaPeriodIdForAds(
            timeline: timeline,
            periodId: periodId,
            position: position,
            windowSequenceNumber: windowSequenceNumber,
            window: window,
            period: period
        )
    }

    private func notifyQueueUpdate() {
        // TODO: collect analytics
    }

    private func resolvePeriodIdToWindowSequenceNumber(_ periodId: AnyHashable, timeline: Timeline) -> Int? {
        let windowIndex = timeline.periodById(periodId, period: period).windowIndex

        if let oldFrontPeriodId, let oldFrontPeriodIndex = timeline.indexOfPeriod(by: oldFrontPeriodId),
           windowIndex == timeline.getPeriod(periodIndex: oldFrontPeriodIndex, period: period).windowIndex {
            return oldFrontPeriodWindowSequenceNumber
        }

        var mediaPeriodHolder = playing
        while let unwrappedHolder = mediaPeriodHolder {
            if unwrappedHolder.id == periodId {
                return unwrappedHolder.info.id.windowSequenceNumber
            }
            mediaPeriodHolder = unwrappedHolder.next
        }

        mediaPeriodHolder = playing
        while let unwrappedHolder = mediaPeriodHolder {
            if let indexOfHolderInTimeline = timeline.indexOfPeriod(by: unwrappedHolder.id),
               windowIndex == timeline.getPeriod(periodIndex: indexOfHolderInTimeline, period: period).windowIndex {
                return unwrappedHolder.info.id.windowSequenceNumber
            }
            mediaPeriodHolder = unwrappedHolder.next
        }

        if let windowSequenceNumber = resolvePeriodIdToWindowSequenceNumberInPreloadPeriods(periodId: periodId) {
            return windowSequenceNumber
        }

        let windowSequenceNumber = nextWindowSequenceNumber
        nextWindowSequenceNumber += 1
        if playing == nil {
            oldFrontPeriodId = periodId
            oldFrontPeriodWindowSequenceNumber = windowSequenceNumber
        }

        return windowSequenceNumber
    }

    private func resolvePeriodIdToWindowSequenceNumberInPreloadPeriods(periodId: AnyHashable) -> Int? {
        preloadPriorityList.first(where: { $0.info.id.periodId == periodId })?.info.id.windowSequenceNumber
    }

    private func canKeepMediaPeriodHolder(oldInfo: MediaPeriodInfo, newInfo: MediaPeriodInfo) -> Bool {
        oldInfo.startPosition == newInfo.startPosition && oldInfo.id == newInfo.id
    }

    private func updateForPlaybackModeChange(with timeline: Timeline) -> UpdatePeriodQueueResult {
        guard var lastValidPeriodHolder = playing else { return [] }

        var currentPeriodIndex = timeline.indexOfPeriod(by: lastValidPeriodHolder.id)
        while true, let periodIndex = currentPeriodIndex {
            let nextPeriodIndex = timeline.nextPeriodIndex(periodIndex: periodIndex,
                                                           period: period,
                                                           window: window,
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
            requestedContentPosition: playbackInfo.requestedContentPosition,
            startPosition: playbackInfo.position
        )
    }

    private func followingMediaPeriodInfo(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        rendererPosition: CMTime
    ) -> MediaPeriodInfo? {
        let mediaPeriodInfo = mediaPeriodHolder.info
        let bufferedDuration = mediaPeriodHolder.renderPositionOffset + mediaPeriodInfo.duration - rendererPosition

        if mediaPeriodInfo.isLastInTimelinePeriod {
            return firstMediaPeriodInfoOfNextPeriod(
                timeline: timeline,
                mediaPeriodHolder: mediaPeriodHolder,
                bufferedDuration: bufferedDuration
            )
        } else {
            return followingMediaPeriodInfoOfCurrentPeriod(
                timeline: timeline,
                mediaPeriodHolder: mediaPeriodHolder,
                bufferedDuration: bufferedDuration
            )
        }
    }

    private func firstMediaPeriodInfoOfNextPeriod(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        bufferedDuration: CMTime
    ) -> MediaPeriodInfo? {
        let mediaPeriodInfo = mediaPeriodHolder.info
        let currentPeriodIndex = timeline.indexOfPeriod(by: mediaPeriodInfo.id.periodId)

        guard let currentPeriodIndex,
              let nextPeriodIndex = timeline.nextPeriodIndex(periodIndex: currentPeriodIndex,
                                                             period: period,
                                                             window: window,
                                                             repeatMode: repeatMode,
                                                             shuffleModeEnabled: shuffleModeEnabled) else {
            return nil
        }

        var startPosition = CMTime.zero
        var contentPosition = CMTime.zero

        let nextWindowIndex = timeline.getPeriod(periodIndex: nextPeriodIndex, period: period, setIds: true).windowIndex
        guard var nextPeriodUid = period.uid else { return nil }

        var windowSequenceNumber = mediaPeriodInfo.id.windowSequenceNumber
        if timeline.getWindow(windowIndex: nextWindowIndex, window: window).firstPeriodIndex == nextPeriodIndex {
            contentPosition = .invalid
            guard let defaultPosition = timeline.periodPosition(window: window,
                                                                period: period,
                                                                windowIndex: nextWindowIndex,
                                                                windowPosition: .invalid,
                                                                defaultPositionProjection: max(.zero, bufferedDuration)) else {
                return nil
            }

            nextPeriodUid = defaultPosition.0
            startPosition = defaultPosition.1

            if let nextMediaPeriodHolder = mediaPeriodHolder.next, nextMediaPeriodHolder.id == nextPeriodUid {
                windowSequenceNumber = nextMediaPeriodHolder.info.id.windowSequenceNumber
            } else {
                if let windowSequenceNumberFromPreload = resolvePeriodIdToWindowSequenceNumberInPreloadPeriods(periodId: nextPeriodUid) {
                    windowSequenceNumber = windowSequenceNumberFromPreload
                } else {
                    windowSequenceNumber = nextWindowSequenceNumber
                    nextWindowSequenceNumber += 1
                }
            }
        }

        guard let windowSequenceNumber else { return nil }

        let periodId = resolveMediaPeriodIdForAds(
            timeline: timeline,
            periodId: nextPeriodUid,
            position: startPosition,
            windowSequenceNumber: windowSequenceNumber,
            window: window,
            period: period
        )

        if contentPosition.isValid, mediaPeriodInfo.requestedContentPosition.isValid {
            // TODO: ad
            
        }

        return getMediaPeriodInfo(
            timeline: timeline,
            id: periodId,
            requestedContentPosition: contentPosition,
            startPosition: startPosition
        )
    }

    private func followingMediaPeriodInfoOfCurrentPeriod(
        timeline: Timeline,
        mediaPeriodHolder: MediaPeriodHolder,
        bufferedDuration: CMTime
    ) -> MediaPeriodInfo?{
        let mediaPeriodInfo = mediaPeriodHolder.info
        let currentPeriodId = mediaPeriodInfo.id
        timeline.periodById(currentPeriodId.periodId, period: period)

        return mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: currentPeriodId.periodId,
            startPosition: period.duration,
            requestedContentPosition: mediaPeriodInfo.duration,
            windowSequenceNumber: currentPeriodId.windowSequenceNumber
        )
    }

    private func getMediaPeriodInfo(
        timeline: Timeline,
        id: MediaPeriodId,
        requestedContentPosition: CMTime,
        startPosition: CMTime
    ) -> MediaPeriodInfo {
        timeline.periodById(id.periodId, period: period)

        return mediaPeriodInfoForContent(
            timeline: timeline,
            periodId: id.periodId,
            startPosition: startPosition,
            requestedContentPosition: requestedContentPosition,
            windowSequenceNumber: id.windowSequenceNumber
        )
    }

    private func mediaPeriodInfoForContent(
        timeline: Timeline,
        periodId: AnyHashable,
        startPosition: CMTime,
        requestedContentPosition: CMTime,
        windowSequenceNumber: Int?
    ) -> MediaPeriodInfo {
        timeline.periodById(periodId, period: period)

        let id = MediaPeriodId(periodId: periodId, windowSequenceNumber: windowSequenceNumber)
        let isLastInPeriod = isLastInPeriod(id: id)
        let isLastInWindow = isLastInWindow(timeline: timeline, id: id)
        let isLastInTimeline = isLastInTimeline(timeline, id: id, isLastMediaPeriodInPeriod: isLastInPeriod)

        let duration = period.duration
        var startPosition = startPosition
        if duration.isValid && startPosition >= duration {
            startPosition = max(.zero, duration - CMTime(value: isLastInTimeline ? 1 : 0, timescale: duration.timescale))
        }
        return MediaPeriodInfo(
            id: id,
            startPosition: startPosition,
            requestedContentPosition: requestedContentPosition,
            endPosition: .invalid,
            duration: duration,
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

        let windowIndex = timeline.periodById(id.periodId, period: period).windowIndex
        let periodIndex = timeline.indexOfPeriod(by: id.periodId)
        return timeline.getWindow(windowIndex: windowIndex, window: window).lastPeriodIndex == periodIndex
    }

    private func isLastInTimeline(_ timeline: Timeline, id: MediaPeriodId, isLastMediaPeriodInPeriod: Bool) -> Bool {
        guard let periodIndex = timeline.indexOfPeriod(by: id.periodId) else {
            return true
        }
        let windowIndex = timeline.getPeriod(periodIndex: periodIndex, period: period).windowIndex
        return isLastMediaPeriodInPeriod && !timeline.getWindow(windowIndex: windowIndex, window: window).isDynamic
            && timeline.isLastPeriod(
                periodIndex: periodIndex,
                period: period,
                window: window,
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

    static let initialRendererPositionOffset: CMTime = CMTime(value: 1_000_000_000_000, timescale: 1_000_000)
    static let maximumBufferAheadPeriods = 100
}
