//
//  MediaPeriodInfo.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.01.2025.
//

import CoreMedia

struct MediaPeriodInfo: Hashable {
    let id: MediaPeriodId
    let startPosition: CMTime
    let requestedContentPosition: CMTime
    let endPosition: CMTime
    let duration: CMTime
    
}

struct MediaPeriodId: Hashable {
    let periodId: UUID
    let windowSequenceNumber: Int
}
