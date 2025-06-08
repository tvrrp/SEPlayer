//
//  MaskingMediaSource.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

import Foundation.NSUUID

final class MaskingMediaSource: WrappingMediaSource {
    let useLazyPreparation: Bool
    var window: Window
    var period: Period

    var timeline: MaskingTimeline
    private var unpreparedMaskingMediaPeriod: MaskingMediaPeriod?

    private var hasStartedPreparing: Bool = false
    private var isPrepared: Bool = false
    private var hasRealTimeline: Bool = false

    init(queue: Queue, mediaSource: MediaSource, useLazyPreparation: Bool) {
        self.useLazyPreparation = useLazyPreparation
        window = Window()
        period = Period()

        if let initialTimeline = mediaSource.getInitialTimeline() {
            timeline = MaskingTimeline.withRealTimeline(initialTimeline, firstWindowId: nil, firstPeriodId: nil)
            hasRealTimeline = true
        } else {
            timeline = MaskingTimeline.placeholder(mediaItem: mediaSource.getMediaItem())
        }

        super.init(queue: queue, mediaSource: mediaSource, mediaItem: mediaSource.getMediaItem())
    }

    override func canUpdateMediaItem(new item: MediaItem) -> Bool {
        mediaSource.canUpdateMediaItem(new: item)
    }

    override func updateMediaItem(new item: MediaItem) {
        timeline = if hasRealTimeline {
            timeline.clone(with: TimelineWithUpdatedMediaItem(
                timeline: timeline.timeline,
                updatedMediaItem: item
            ))
        } else {
            MaskingTimeline.placeholder(mediaItem: item)
        }
        mediaSource.updateMediaItem(new: item)
    }

    override func prepareSourceInternal() {
        if !useLazyPreparation {
            hasStartedPreparing = true
            prepareChildSource()
        }
    }

    override func createPeriod(id: MediaPeriodId, allocator: Allocator, startPosition: Int64) -> any MediaPeriod {
        let mediaPeriod = MaskingMediaPeriod(id: id, allocator: allocator, preparePositionUs: startPosition)
        mediaPeriod.setMediaSource(mediaSource)
        if isPrepared {
            let idInSource = id.copy(with: internalPeriodId(for: id.periodId))
            mediaPeriod.createPeriod(id: idInSource)
        } else {
            unpreparedMaskingMediaPeriod = mediaPeriod
            if !hasStartedPreparing {
                hasStartedPreparing = true
                prepareChildSource()
            }
        }

        return mediaPeriod
    }

    override func release(mediaPeriod: any MediaPeriod) {
        (mediaPeriod as? MaskingMediaPeriod)?.releasePeriod()
        if mediaPeriod === unpreparedMaskingMediaPeriod {
            unpreparedMaskingMediaPeriod = nil
        }
    }

    override func releaseSourceInternal() {
        isPrepared = false
        hasStartedPreparing = false
        super.releaseSourceInternal()
    }

    override func onChildSourceInfoRefreshed(newTimeline: Timeline) {
        var idForMaskingPeriodPreparation: MediaPeriodId?

        if isPrepared {
            timeline = timeline.clone(with: newTimeline)
            if let unpreparedMaskingMediaPeriod {
                setPreparePositionOverrideToUnpreparedMaskingPeriod(
                    unpreparedMaskingMediaPeriod.preparePositionOverrideUs
                )
            }
        } else if newTimeline.isEmpty {
            timeline = if hasRealTimeline {
                timeline.clone(with: newTimeline)
            } else {
                MaskingTimeline.withRealTimeline(
                    newTimeline,
                    firstWindowId: Window.singleWindowId,
                    firstPeriodId: MaskingTimeline.maskingExternalPeriodId
                )
            }
        } else {
            newTimeline.getWindow(windowIndex: 0, window: &window)
            var windowStartPositionUs = window.defaultPositionUs
            let windowId = window.id

            if let unpreparedMaskingMediaPeriod {
                let periodPreparePositionUs = unpreparedMaskingMediaPeriod.preparePositionUs
                timeline.periodById(unpreparedMaskingMediaPeriod.id.periodId, period: &period)
                let windowPreparePositionUs = period.positionInWindowUs + periodPreparePositionUs
                let oldWindowDefaultPositionUs = timeline.getWindow(windowIndex: 0, window: &window).defaultPositionUs
                if windowPreparePositionUs != oldWindowDefaultPositionUs {
                    windowStartPositionUs = windowPreparePositionUs
                }
            }

            guard let (periodId, periodPositionUs) = newTimeline.periodPositionUs(
                window: &window,
                period: &period,
                windowIndex: 0,
                windowPositionUs: windowStartPositionUs
            ) else { return }

            timeline = if hasRealTimeline {
                timeline.clone(with: newTimeline)
            } else {
                MaskingTimeline.withRealTimeline(newTimeline, firstWindowId: windowId, firstPeriodId: periodId)
            }

            if let maskingPeriod = unpreparedMaskingMediaPeriod,
               setPreparePositionOverrideToUnpreparedMaskingPeriod(periodPositionUs) {
                idForMaskingPeriodPreparation = maskingPeriod.id
                    .copy(with: internalPeriodId(for: maskingPeriod.id.periodId))
            }
        }

        hasRealTimeline = true
        isPrepared = true
        refreshSourceInfo(timeline: timeline)
        if let idForMaskingPeriodPreparation, let unpreparedMaskingMediaPeriod {
            unpreparedMaskingMediaPeriod.createPeriod(id: idForMaskingPeriodPreparation)
        }
    }

    private func mediaPeriodId(forChild mediaPeriodId: MediaPeriodId) -> MediaPeriodId {
        mediaPeriodId.copy(with: externalPeriodId(for: mediaPeriodId.periodId))
    }

    private func internalPeriodId(for externalPeriodId: AnyHashable) -> AnyHashable {
        if let replacedInternalPeriodId = timeline.replacedInternalPeriodId,
           externalPeriodId == MaskingTimeline.maskingExternalPeriodId {
            return replacedInternalPeriodId
        } else {
            return externalPeriodId
        }
    }

    private func externalPeriodId(for internalPeriodId: AnyHashable) -> AnyHashable {
        if let replacedInternalPeriodId = timeline.replacedInternalPeriodId,
           replacedInternalPeriodId == internalPeriodId {
            return MaskingTimeline.maskingExternalPeriodId
        } else {
            return internalPeriodId
        }
    }

    @discardableResult
    private func setPreparePositionOverrideToUnpreparedMaskingPeriod(_ preparePositionOverrideUs: Int64) -> Bool {
        var preparePositionOverrideUs = preparePositionOverrideUs
        let maskingPeriod = unpreparedMaskingMediaPeriod
        guard let maskingPeriodIndex = timeline.indexOfPeriod(by: maskingPeriod?.id.periodId) else {
            return false
        }

        let periodDurationUs = timeline.getPeriod(periodIndex: maskingPeriodIndex, period: &period).durationUs
        if periodDurationUs != .timeUnset, preparePositionOverrideUs >= periodDurationUs {
            preparePositionOverrideUs = max(0, periodDurationUs - 1)
        }
        maskingPeriod?.preparePositionOverrideUs = preparePositionOverrideUs
        return true
    }
}

extension MaskingMediaSource {
    final class MaskingTimeline: ForwardingTimeline, @unchecked Sendable {
        static let maskingExternalPeriodId: AnyHashable = UUID()
        let replacedInternalWindowId: AnyHashable?
        let replacedInternalPeriodId: AnyHashable?

        init(
            timeline: Timeline,
            replacedInternalWindowId: AnyHashable?,
            replacedInternalPeriodId: AnyHashable?
        ) {
            self.replacedInternalWindowId = replacedInternalWindowId
            self.replacedInternalPeriodId = replacedInternalPeriodId
            super.init(timeline: timeline)
        }

        func clone(with updatedTimeline: Timeline) -> MaskingTimeline {
            MaskingTimeline(
                timeline: updatedTimeline,
                replacedInternalWindowId: replacedInternalWindowId,
                replacedInternalPeriodId: replacedInternalPeriodId
            )
        }

        override func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
            timeline.getWindow(windowIndex: windowIndex, window: &window, defaultPositionProjectionUs: defaultPositionProjectionUs)
            if window.id == replacedInternalWindowId {
                window.id = Window.singleWindowId
            }
            return window
        }

        override func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
            timeline.getPeriod(periodIndex: periodIndex, period: &period, setIds: setIds)
            if period.uid == replacedInternalPeriodId, setIds {
                period.uid = Self.maskingExternalPeriodId
            }
            return period
        }

        override func indexOfPeriod(by id: AnyHashable) -> Int? {
            let id = if let replacedInternalPeriodId, Self.maskingExternalPeriodId == id {
                replacedInternalPeriodId
            } else {
                id
            }

            return timeline.indexOfPeriod(by: id)
        }

        override func id(for periodIndex: Int) -> AnyHashable {
            let id = timeline.id(for: periodIndex)
            return id == replacedInternalPeriodId ? Self.maskingExternalPeriodId : id
        }

        static func placeholder(mediaItem: MediaItem) -> MaskingTimeline {
            MaskingTimeline(
                timeline: PlaceholderTimeline(mediaItem: mediaItem),
                replacedInternalWindowId: Window.singleWindowId,
                replacedInternalPeriodId: Self.maskingExternalPeriodId
            )
        }

        static func withRealTimeline(
            _ timeline: Timeline,
            firstWindowId: AnyHashable?,
            firstPeriodId: AnyHashable?
        ) -> MaskingTimeline {
            MaskingTimeline(
                timeline: timeline,
                replacedInternalWindowId: firstWindowId,
                replacedInternalPeriodId: firstPeriodId
            )
        }
    }

    struct PlaceholderTimeline: Timeline {
        private let mediaItem: MediaItem

        init(mediaItem: MediaItem) {
            self.mediaItem = mediaItem
        }

        func windowCount() -> Int { 1 }

        func getWindow(windowIndex: Int, window: inout Window, defaultPositionProjectionUs: Int64) -> Window {
            window = Window(
                id: Window.singleWindowId,
                mediaItem: mediaItem,
                presentationStartTimeMs: .timeUnset,
                windowStartTimeMs: .timeUnset,
                elapsedRealtimeEpochOffsetMs: .timeUnset,
                isSeekable: false,
                isDynamic: false,
                isPlaceholder: true,
                defaultPositionUs: .zero,
                durationUs: .timeUnset,
                firstPeriodIndex: 0,
                lastPeriodIndex: 0,
                positionInFirstPeriodUs: 0
            )
            return window
        }

        func periodCount() -> Int { 1 }

        func getPeriod(periodIndex: Int, period: inout Period, setIds: Bool) -> Period {
            period = Period(
                id: setIds ? 0 : nil,
                uid: setIds ? MaskingTimeline.maskingExternalPeriodId : nil,
                windowIndex: 0,
                durationUs: .timeUnset,
                positionInWindowUs: 0,
                isPlaceholder: true
            )
            return period
        }

        func indexOfPeriod(by id: AnyHashable) -> Int? {
            id == MaskingTimeline.maskingExternalPeriodId ? 0 : nil
        }

        func id(for periodIndex: Int) -> AnyHashable {
            MaskingTimeline.maskingExternalPeriodId
        }
    }
}
