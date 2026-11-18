//
//  MediaPeriodInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia
import Foundation.NSUUID

struct MediaPeriodInfo: Hashable {
    let id: MediaPeriodId
    let startPosition: CMTime
    let requestedContentPosition: CMTime
    let endPosition: CMTime
    let duration: CMTime
    let isLastInTimelinePeriod: Bool
    let isLastInTimelineWindow: Bool
    let isFinal: Bool

    func copyWithStartPosition(_ position: CMTime) -> MediaPeriodInfo {
        guard position != startPosition else { return self }

        return MediaPeriodInfo(
            id: id,
            startPosition: position,
            requestedContentPosition: requestedContentPosition,
            endPosition: endPosition,
            duration: duration,
            isLastInTimelinePeriod: isLastInTimelinePeriod,
            isLastInTimelineWindow: isLastInTimelineWindow,
            isFinal: isFinal
        )
    }

    func copyWithRequestedContentPosition(_ requestedContentPosition: CMTime) -> MediaPeriodInfo {
        guard self.requestedContentPosition != requestedContentPosition else {
            return self
        }

        return MediaPeriodInfo(
            id: id,
            startPosition: startPosition,
            requestedContentPosition: requestedContentPosition,
            endPosition: endPosition,
            duration: duration,
            isLastInTimelinePeriod: isLastInTimelinePeriod,
            isLastInTimelineWindow: isLastInTimelineWindow,
            isFinal: isFinal
        )
    }
}

public struct MediaPeriodId: Hashable {
    let periodId: AnyHashable
    let windowSequenceNumber: Int?

    public init(periodId: AnyHashable = UUID(), windowSequenceNumber: Int? = nil) {
        self.periodId = periodId
        self.windowSequenceNumber = windowSequenceNumber
    }

    func copy(with newPeriodId: AnyHashable) -> MediaPeriodId {
        periodId == newPeriodId ? self : MediaPeriodId(periodId: newPeriodId, windowSequenceNumber: windowSequenceNumber)
    }
}
