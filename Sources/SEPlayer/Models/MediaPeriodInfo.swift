//
//  MediaPeriodInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia

struct MediaPeriodInfo: Hashable {
    let id: MediaPeriodId
    let startPositionUs: Int64
    let requestedContentPositionUs: Int64
    let endPositionUs: Int64
    let durationUs: Int64
    let isLastInTimelinePeriod: Bool
    let isLastInTimelineWindow: Bool
    let isFinal: Bool

    func copyWithStartPositionUs(_ positionUs: Int64) -> MediaPeriodInfo {
        guard positionUs != startPositionUs else { return self }

        return MediaPeriodInfo(
            id: id,
            startPositionUs: positionUs,
            requestedContentPositionUs: requestedContentPositionUs,
            endPositionUs: endPositionUs,
            durationUs: durationUs,
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
        periodId == newPeriodId ? self : MediaPeriodId(periodId: periodId, windowSequenceNumber: windowSequenceNumber)
    }
}
