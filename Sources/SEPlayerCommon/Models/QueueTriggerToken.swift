//
//  QueueTriggerToken.swift
//  SEPlayer
//
//  Created by tvrrp on 16.03.2026.
//

import CoreMedia

public typealias TriggerCondition = CMBufferQueue.TriggerCondition
//@frozen public enum TriggerCondition {
//    /// Fires when buffered-ahead duration drops below the threshold.
//    case whenDurationBecomesLessThan(Int64)
//    case whenDurationBecomesLessThanOrEqualTo(Int64)
//    /// Fires when buffered-ahead duration rises above the threshold.
//    case whenDurationBecomesGreaterThan(Int64)
//    case whenDurationBecomesGreaterThanOrEqualTo(Int64)
//    /// Fires each time the earliest readable timestamp changes.
//    case whenMinPresentationTimestampChanges
//    /// Fires each time the latest queued timestamp changes.
//    case whenMaxPresentationTimestampChanges
//    /// Fires when at least one sample becomes readable.
//    case whenDataBecomesReady
//    /// Fires when upstream has finished writing and all samples have been read.
//    case whenEndOfDataReached
//    /// Fires immediately on reset() / release() — not edge-detected.
//    case whenReset
//    case whenSampleCountBecomesLessThan(Int)
//    case whenSampleCountBecomesGreaterThan(Int)
//}

public typealias QueueTriggerToken = UUID

//public struct QueueTriggerToken: Hashable, Sendable {
//    public let id: UUID
//
//    public init() {
//        id = UUID()
//    }
//
////    public init(cmTrigger: CMBufferQueueTriggerToken) {
////        id = .cmTrigger(cmTrigger)
////    }
//}
