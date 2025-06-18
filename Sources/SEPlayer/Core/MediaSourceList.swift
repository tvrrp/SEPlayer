//
//  MediaSourceList.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import Foundation.NSUUID

protocol MediaSourceInfoHolder {
    var id: AnyHashable { get }
    var timeline: Timeline { get }
}

final class MediaSourceList {
    protocol Delegate: AnyObject {
        func playlistUpdateRequested()
    }

    weak var delegate: Delegate?
    var isPrepared: Bool = false

    private let playerId: UUID
    private var mediaSourceHolders: [MediaSourceHolder]
    private var mediaSourceByMediaPeriod: [MediaPeriodHolder: MediaSourceHolder]
    private var mediaSourceById: [AnyHashable: MediaSourceHolder]
    private var childSources: [MediaSourceHolder: MediaSourceDelegateHolder]
    private var enabledMediaSourceHolders: Set<MediaSourceHolder>

    private var mediaTransferListener: TransferListener?

    var shuffleOrder: ShuffleOrder

    init(playerId: UUID) {
        self.playerId = playerId
        mediaSourceHolders = []
        mediaSourceByMediaPeriod = [:]
        mediaSourceById = [:]
        childSources = [:]
        enabledMediaSourceHolders = .init()
        isPrepared = false
        shuffleOrder = DefaultShuffleOrder(length: .zero)
    }

    func setMediaSource(holders: [MediaSourceHolder], shuffleOrder: ShuffleOrder) -> Timeline {
        removeMediaSourcesInternal(range: 0..<mediaSourceHolders.count)
        return addMediaSource(index: mediaSourceHolders.count, holders: holders, shuffleOrder: shuffleOrder)
    }

    func addMediaSource(index: Int, holders: [MediaSourceHolder], shuffleOrder: ShuffleOrder) -> Timeline {
        if !holders.isEmpty {
            self.shuffleOrder = shuffleOrder
            for insertionIndex in index..<index + holders.count {
                let holder = holders[insertionIndex - index]
                if insertionIndex > 0 {
                    let previousHolder = mediaSourceHolders[insertionIndex - 1]
                    let previousTimeline = previousHolder.mediaSource.timeline
                    holder.reset(
                        firstWindowIndexInChild: previousHolder.firstWindowIndexInChild + previousTimeline.windowCount()
                    )
                } else {
                    holder.reset(firstWindowIndexInChild: 0)
                }

                let newTimeline = holder.mediaSource.timeline
                correctOffsets(start: insertionIndex, windowOffsetUpdate: newTimeline.windowCount())
                mediaSourceHolders.insert(holder, at: insertionIndex)
                mediaSourceById[holder.id] = holder
                if isPrepared {
                    prepareChildSource(from: holder)
                    if mediaSourceByMediaPeriod.isEmpty {
                        enabledMediaSourceHolders.insert(holder)
                    } else {
                        disableChildSource(holder: holder)
                    }
                }
            }
        }

        return createTimeline()
    }

    func removeMediaSource(range: Range<Int>, shuffleOrder: ShuffleOrder) -> Timeline {
        self.shuffleOrder = shuffleOrder
        removeMediaSourcesInternal(range: range)
        return createTimeline()
    }

    func moveMediaSource(from currentIndex: Int, to newIndex: Int, shuffleOrder: ShuffleOrder) -> Timeline {
        moveMediaSourceRange(
            range: Range<Int>(currentIndex...newIndex),
            to: newIndex,
            shuffleOrder: shuffleOrder
        )
    }

    func moveMediaSourceRange(range: Range<Int>, to newIndex: Int, shuffleOrder: ShuffleOrder) -> Timeline {
        self.shuffleOrder = shuffleOrder
        if range.count == 0 || range.lowerBound == newIndex {
            return createTimeline()
        }

        let startIndex = min(range.lowerBound, newIndex)
        let newEndIndex = newIndex + (range.upperBound - range.lowerBound) - 1
        let endIndex = max(newEndIndex, range.upperBound - 1)
        var windowOffset = mediaSourceHolders[startIndex].firstWindowIndexInChild
        if #available(iOS 18.0, *) {
            mediaSourceHolders.moveSubranges(.init(range), to: newIndex)
        } else {
            let removed = mediaSourceHolders[range]
            mediaSourceHolders.removeSubrange(range)
            mediaSourceHolders.insert(contentsOf: removed, at: newIndex)
        }

        for index in startIndex...endIndex {
            let holder = mediaSourceHolders[index]
            holder.firstWindowIndexInChild = windowOffset
            windowOffset += holder.mediaSource.timeline.windowCount()
        }

        return createTimeline()
    }

    func updateMediaSources(with mediaItems: [MediaItem], range: Range<Int>) -> Timeline {
        for index in range {
            mediaSourceHolders[index]
                .mediaSource
                .updateMediaItem(new: mediaItems[index - range.lowerBound])
        }

        return createTimeline()
    }

    func clear(shuffleOrder: ShuffleOrder?) -> Timeline {
        self.shuffleOrder = if let shuffleOrder {
            shuffleOrder
        } else {
            self.shuffleOrder.cloneAndClear()
        }
        removeMediaSourcesInternal(range: 0..<getSize())
        return createTimeline()
    }

    func getSize() -> Int { mediaSourceHolders.count }

    func setShuffleOrder(new shuffleOrder: ShuffleOrder) -> Timeline {
        var shuffleOrder = shuffleOrder
        let size = getSize()
        if shuffleOrder.count != size {
            shuffleOrder = shuffleOrder
                .cloneAndClear()
                .cloneAndInsert(insertionIndex: .zero, insertionCount: size)
        }
        self.shuffleOrder = shuffleOrder
        return createTimeline()
    }

    func prepare(mediaTransferListener: TransferListener?) throws {
        guard !isPrepared else { assertionFailure(); return }

        self.mediaTransferListener = mediaTransferListener
        for holder in mediaSourceHolders {
            prepareChildSource(from: holder)
            enabledMediaSourceHolders.insert(holder)
        }
        isPrepared = true
    }

    func createPeriod(
        id: MediaPeriodId,
        allocator: Allocator,
        startPosition: Int64
    ) throws -> MediaPeriod {
        let mediaSourceHolderId = mediaSourceHolderId(for: id.periodId)
        let childMediaPeriodId = id.copy(with: childPeriodId(from: id.periodId))
        guard let holder = mediaSourceById[mediaSourceHolderId] else {
            throw ErrorBuilder(errorDescription: "Holder is missing")
        }

        enableMediaSource(holder: holder)
        holder.activeMediaPeriodIds.append(childMediaPeriodId)
        let mediaPeriod = holder.mediaSource.createPeriod(
            id: childMediaPeriodId,
            allocator: allocator,
            startPosition: startPosition
        )

        mediaSourceByMediaPeriod[.init(period: mediaPeriod)] = holder
        disableUnusedMediaSources()
        return mediaPeriod
    }

    func releasePeriod(mediaPeriod: MediaPeriod) {
        if let holder = mediaSourceByMediaPeriod.removeValue(forKey: MediaPeriodHolder(period: mediaPeriod)) {
            holder.mediaSource.release(mediaPeriod: mediaPeriod)
            let id = (mediaPeriod as! MaskingMediaPeriod).id
            holder.activeMediaPeriodIds.removeAll(where: { $0 == id })
            if !mediaSourceByMediaPeriod.isEmpty {
                disableUnusedMediaSources()
            }
            releaseChildSource(from: holder)
        }
    }

    func release() {
        childSources.values.forEach { $0.source.releaseSource(delegate: $0.delegate) }
        childSources.removeAll()
        enabledMediaSourceHolders.removeAll()
        isPrepared = false
    }

    func createTimeline() -> Timeline {
        guard !mediaSourceHolders.isEmpty else { return EmptyTimeline() }

        var windowOffset = 0
        for mediaSourceHolder in mediaSourceHolders {
            mediaSourceHolder.firstWindowIndexInChild = windowOffset
            windowOffset += mediaSourceHolder.mediaSource.timeline.windowCount()
        }

        return PlaylistTimeline(
            mediaSourceInfoHolders: mediaSourceHolders,
            shuffleOrder: shuffleOrder
        )
    }
}

extension MediaSourceList: MediaSourceDelegate {
    func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline) {
        delegate?.playlistUpdateRequested()
    }
}

private extension MediaSourceList {
    func enableMediaSource(holder: MediaSourceHolder) {
        enabledMediaSourceHolders.insert(holder)
        if let enabledChild = childSources[holder] {
            enabledChild.source.enable(delegate: enabledChild.delegate)
        }
    }

    func disableUnusedMediaSources() {
        let unusedHolders = enabledMediaSourceHolders.filter { $0.activeMediaPeriodIds.isEmpty }
        for holder in unusedHolders {
            disableChildSource(holder: holder)
            enabledMediaSourceHolders.remove(holder)
        }
    }

    func disableChildSource(holder: MediaSourceHolder) {
        if let disabledChild = childSources[holder] {
            disabledChild.source.disable(delegate: disabledChild.delegate)
        }
    }

    func removeMediaSourcesInternal(range: Range<Int>) {
        for index in range.reversed() {
            let holder = mediaSourceHolders.remove(at: index)
            mediaSourceById.removeValue(forKey: holder.id)
            let oldTimelime = holder.mediaSource.timeline
            correctOffsets(start: index, windowOffsetUpdate: -oldTimelime.windowCount())
            holder.isRemoved = true
            if isPrepared {
                releaseChildSource(from: holder)
            }
        }
    }

    func correctOffsets(start: Int, windowOffsetUpdate: Int) {
        for index in start..<mediaSourceHolders.count {
            mediaSourceHolders[index].firstWindowIndexInChild += windowOffsetUpdate
        }
    }

    func mediaPeriodIdForChild(for mediaPeriodId: MediaPeriodId, mediaSourceHolder: MediaSourceHolder) -> MediaPeriodId? {
        for activeMediaPeriodId in mediaSourceHolder.activeMediaPeriodIds {
            if activeMediaPeriodId.windowSequenceNumber == mediaPeriodId.windowSequenceNumber {
                let periodId = periodId(
                    holder: mediaSourceHolder,
                    childPeriodId: mediaPeriodId.periodId
                )
                return mediaPeriodId.copy(with: periodId)
            }
        }

        return nil
    }

    func windowIndexForChild(windowIndex: Int, mediaSourceHolder: MediaSourceHolder) -> Int {
        windowIndex + mediaSourceHolder.firstWindowIndexInChild
    }
}

private extension MediaSourceList {
    func prepareChildSource(from holder: MediaSourceHolder) {
        let mediaSource = holder.mediaSource
        childSources[holder] = MediaSourceDelegateHolder(source: mediaSource, delegate: self)
        mediaSource.prepareSource(delegate: self, mediaTransferListener: mediaTransferListener, playerId: playerId)
    }

    func releaseChildSource(from holder: MediaSourceHolder) {
        if holder.isRemoved && holder.activeMediaPeriodIds.isEmpty {
            if let removedChild = childSources.removeValue(forKey: holder) {
                removedChild.source.releaseSource(delegate: removedChild.delegate)
                enabledMediaSourceHolders.remove(holder)
            }
        }
    }
}

private extension MediaSourceList {
    func mediaSourceHolderId(for periodId: AnyHashable) -> AnyHashable {
        PlaylistTimeline.childTimelineId(from: periodId)
    }

    func childPeriodId(from periodId: AnyHashable) -> AnyHashable {
        PlaylistTimeline.childPeriodId(from: periodId)
    }

    func periodId(holder: MediaSourceHolder, childPeriodId: AnyHashable) -> AnyHashable {
        PlaylistTimeline.concatenatedId(childTimelineId: holder.id, childPeriodOrWindowId: childPeriodId)
    }
}

extension MediaSourceList {
    private struct MediaPeriodHolder: Hashable {
        let period: any MediaPeriod

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(period))
        }

        static func == (lhs: MediaPeriodHolder, rhs: MediaPeriodHolder) -> Bool {
            return lhs.period === rhs.period
        }
    }

    private struct MediaSourceDelegateHolder {
        let source: MediaSource
        let delegate: MediaSourceDelegate
    }

    final class MediaSourceHolder: MediaSourceInfoHolder, Hashable {
        var timeline: Timeline { mediaSource.timeline }
        let mediaSource: MaskingMediaSource
        let id: AnyHashable
        var activeMediaPeriodIds: [MediaPeriodId]

        var firstWindowIndexInChild: Int
        var isRemoved: Bool

        init(queue: Queue, mediaSource: MediaSource, useLazyPreparation: Bool) {
            id = UUID()
            activeMediaPeriodIds = []
            self.mediaSource = MaskingMediaSource(queue: queue, mediaSource: mediaSource, useLazyPreparation: useLazyPreparation)
            firstWindowIndexInChild = 0
            isRemoved = false
        }

        func reset(firstWindowIndexInChild: Int) {
            self.firstWindowIndexInChild = firstWindowIndexInChild
            isRemoved = false
            activeMediaPeriodIds.removeAll()
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: MediaSourceList.MediaSourceHolder, rhs: MediaSourceList.MediaSourceHolder) -> Bool {
            lhs.id == rhs.id
        }
    }
}
