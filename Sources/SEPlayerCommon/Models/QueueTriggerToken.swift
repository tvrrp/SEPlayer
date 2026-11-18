//
//  QueueTriggerToken.swift
//  SEPlayer
//
//  Created by tvrrp on 16.03.2026.
//

import CoreMedia

/// When a trigger of a queue of media fires.
public enum TriggerCondition: Sendable, Hashable {
    /// When the duration of the queue drops below the threshold.
    case whenDurationBecomesLessThan(CMTime)
    case whenDurationBecomesLessThanOrEqualTo(CMTime)
    /// When the duration of the queue rises above the threshold.
    case whenDurationBecomesGreaterThan(CMTime)
    case whenDurationBecomesGreaterThanOrEqualTo(CMTime)
    /// Each time the earliest presentation time changes.
    case whenMinPresentationTimeStampChanges
    /// Each time the latest presentation time changes.
    case whenMaxPresentationTimeStampChanges
    /// When the latest presentation time reaches the time: the queue holds media up to it.
    case whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo(CMTime)
    /// When the next buffer to dequeue is ready.
    case whenDataBecomesReady
    /// When the queue has been marked as ended and is empty.
    case whenEndOfDataReached
    /// When the queue is reset.
    case whenReset
    case whenBufferCountBecomesLessThan(Int)
    case whenBufferCountBecomesGreaterThan(Int)
}

public typealias QueueTriggerToken = UUID
