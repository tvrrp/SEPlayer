//
//  MediaPeriodInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia

struct MediaPeriodInfo: Hashable {
    let id: MediaPeriodId
    let startPosition: Int64
    let requestedContentPosition: Int64
    let endPosition: Int64
    let duration: Int64
    let isFinal: Bool

    func withUpdatedStartPosition(_ position: Int64) -> MediaPeriodInfo {
        guard position != startPosition else { return self }

        return MediaPeriodInfo(
            id: id,
            startPosition: position,
            requestedContentPosition: requestedContentPosition,
            endPosition: endPosition,
            duration: duration,
            isFinal: isFinal
        )
    }
}

struct MediaPeriodId: Hashable {
    let periodId: UUID
    let windowSequenceNumber: Int
}
