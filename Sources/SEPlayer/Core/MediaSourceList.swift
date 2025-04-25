//
//  MediaSourceList.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia
import Foundation

protocol MediaSourceInfoHolder {
    var id: UUID { get }
    var timeline: Timeline? { get set }
}

final class MediaSourceList {
    protocol Delegate: AnyObject {
        func playlistUpdateRequested()
    }

    weak var delegate: Delegate?

    private let playerId: UUID
    private var mediaSourceHolders: [MediaSourceHolder]
    private var mediaSourceByMediaPeriod: [MediaPeriodHolder: MediaSourceHolder]
    private var childSources: [MediaSourceHolder: MediaSourceDelegateHolder]
    private var enabledMediaSourceHolders: Set<MediaSourceHolder>

    private var isPrepared: Bool
    private var mediaTransferListener: TransferListener?

    init(delegate: Delegate, playerId: UUID) {
        self.delegate = delegate
        self.playerId = playerId
        mediaSourceHolders = []
        mediaSourceByMediaPeriod = [:]
        childSources = [:]
        enabledMediaSourceHolders = .init()
        isPrepared = false
    }

    func setMediaSource(holders: [MediaSourceHolder]) {
        removeMediaSources(range: 0..<mediaSourceHolders.count)
        addMediaSource(index: mediaSourceHolders.count, holders: holders)
    }

    func addMediaSource(index: Int, holders: [MediaSourceHolder]) {
        if !holders.isEmpty {
            for insertionIndex in index..<index + holders.count {
                var holder = holders[insertionIndex - index]
                if insertionIndex > 0 {
//                    let previousHolder = mediaSourceHolders[insertionIndex - 1]
                    holder.reset(firstWindowIndexInChild: 0) // TODO: implement real timeline
                } else {
                    holder.reset(firstWindowIndexInChild: 0)
                }
                
                // TODO: implement real timeline
//                correctOffsets(start: <#T##Int#>, windowOffsetUpdate: <#T##Int#>)
                mediaSourceHolders.insert(holder, at: insertionIndex)
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
//        return createTimeline()
    }

    func prepare(mediaTransferListener: TransferListener?) throws {
        guard !isPrepared else { return } // TODO: Throw
        self.mediaTransferListener = mediaTransferListener
        for holder in mediaSourceHolders {
            prepareChildSource(from: holder)
            enabledMediaSourceHolders.insert(holder)
        }
        isPrepared = true
    }

    func createPeriod(
        id: MediaPeriodId,
//        allocator: Allocator,
        allocator: Allocator2,
        loadCondition: LoadConditionCheckable,
        startPosition: CMTime
    ) -> MediaPeriod {
        var holder = mediaSourceHolders[0]
        enableMediaSource(holder: holder)
        holder.activeMediaPeriodIds.append(id)
        let period = holder.mediaSource.createPeriod(
            id: holder.activeMediaPeriodIds[0],
            allocator: allocator,
            startPosition: startPosition,
            loadCondition: loadCondition,
            mediaSourceEventDelegate: ForwardingEventListener(id: holder)
        )
        mediaSourceByMediaPeriod[MediaPeriodHolder(period: period)] = holder
        disableUnusedMediaSources()
        return period
    }

    func releasePeriod(mediaPeriod: MediaPeriod) {
        if let holder = mediaSourceByMediaPeriod.removeValue(forKey: MediaPeriodHolder(period: mediaPeriod)) {
            holder.mediaSource.release(mediaPeriod: mediaPeriod)
//            holder.activeMediaPeriodIds.remove(at: <#T##Int#>)
            if !mediaSourceByMediaPeriod.isEmpty {
                disableUnusedMediaSources()
            }
            releaseChildSource(from: holder)
        }
    }
}

extension MediaSourceList: MediaSourceDelegate {
    func mediaSource(_ source: MediaSource, sourceInfo refreshed: Timeline?) {
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
        for holder in enabledMediaSourceHolders {
            if holder.activeMediaPeriodIds.isEmpty {
                disableChildSource(holder: holder)
            }
        }
    }

    func disableChildSource(holder: MediaSourceHolder) {
        if let disabledChild = childSources[holder] {
            disabledChild.source.disable(delegate: disabledChild.delegate)
        }
    }

    func removeMediaSources(range: Range<Int>) {
        for index in range.reversed() {
            var holder = mediaSourceHolders.remove(at: index)
//            let oldTimelime = holder.mediaSource.
            correctOffsets(start: index, windowOffsetUpdate: 1)
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
}

private extension MediaSourceList {
    func prepareChildSource(from holder: MediaSourceHolder) {
        let mediaSource = holder.mediaSource
        let eventListener = ForwardingEventListener(id: holder)
        childSources[holder] = MediaSourceDelegateHolder(source: mediaSource, delegate: self, eventListener: eventListener)
        mediaSource.addEventListener(eventListener)
        mediaSource.prepareSource(delegate: self, mediaTransferListener: mediaTransferListener, playerId: playerId)
    }

    func releaseChildSource(from holder: MediaSourceHolder) {
        if holder.isRemoved && holder.activeMediaPeriodIds.isEmpty {
            if let removedChild = childSources.removeValue(forKey: holder) {
                removedChild.source.releaseSource(delegate: removedChild.delegate)
                removedChild.source.removeEventListener(removedChild.eventListener)
                enabledMediaSourceHolders.remove(holder)
            }
        }
    }
}

private extension MediaSourceList {
    var mediaSourceById: [(UUID, MediaSourceHolder)] {
        mediaSourceHolders.map { ($0.id, $0) }
    }
}

extension MediaSourceList {
    private struct MediaPeriodHolder: Hashable {
        let period: any MediaPeriod

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(period))
        }

        static func == (lhs: MediaPeriodHolder, rhs: MediaPeriodHolder) -> Bool {
            return ObjectIdentifier(lhs.period) == ObjectIdentifier(rhs.period)
        }
    }

    private struct MediaSourceDelegateHolder {
        let source: BaseMediaSource
        let delegate: MediaSourceDelegate
        let eventListener: MediaSourceEventListener
    }

    struct MediaSourceHolder: MediaSourceInfoHolder, Hashable {
        let id: UUID
        var timeline: Timeline?

        let mediaSource: BaseMediaSource
        var activeMediaPeriodIds: [MediaPeriodId]

        var firstWindowIndexInChild: Int
        var isRemoved: Bool

        init(mediaSource: BaseMediaSource) {
            id = UUID()
            activeMediaPeriodIds = []
            self.mediaSource = mediaSource
            firstWindowIndexInChild = 0
            isRemoved = false
        }

        mutating func reset(firstWindowIndexInChild: Int) {
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

private extension MediaSourceList {
    final class ForwardingEventListener: MediaSourceEventListener {
        let id: MediaSourceHolder

        init(id: MediaSourceHolder) {
            self.id = id
        }

        func loadStarted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
            
        }

        func loadCompleted(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
            
        }

        func loadCancelled(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void) {
            
        }

        func loadError(windowIndex: Int, mediaPeriodId: MediaPeriodId?, loadEventInfo: Void, mediaLoadData: Void, error: any Error, wasCancelled: Bool) {
            
        }

        func formatChanged(windowIndex: Int, mediaPeriodId: MediaPeriodId?, mediaLoadData: Void) {
            
        }
    }
}
