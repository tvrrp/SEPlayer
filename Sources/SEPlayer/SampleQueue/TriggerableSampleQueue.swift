//
//  TriggerableSampleQueue.swift
//  SEPlayer
//
//  Created by tvrrp on 15.03.2026.
//

import CoreMedia
import Decoder
import SEPlayerCommon

open class TriggerableQueue {
    public var bufferedAheadDuration: CMTime { .invalid }
    public var readableSampleCount: Int { 0 }
    public var minReadableTimestamp: CMTime? { .invalid }
    public var hasReadableSamples: Bool { false }
    public var isEndOfData: Bool { true }
    public var backBufferDuration: CMTime? { .invalid }

    private let triggersLock = UnfairLock()
    private var triggers: [QueueTriggerToken: InstalledTrigger] = [:]

    @discardableResult
    public final func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)? = nil) -> QueueTriggerToken {
        let token = QueueTriggerToken()
        let snapshot = makeSnapshot()

        let initialResult = evaluate(
            condition: condition, snapshot: snapshot,
            refMinPTS: snapshot.minPTS, refMaxPTS: snapshot.maxPTS
        )

        let trigger = InstalledTrigger(
            token: token, condition: condition, body: body,
            lastResult: initialResult,
            referenceMinPTS: snapshot.minPTS,
            referenceMaxPTS: snapshot.maxPTS
        )

        triggersLock.withLock { triggers[token] = trigger }

        if initialResult { body?(token) }

        return token
    }

    public final func removeTrigger(_ token: QueueTriggerToken) {
        _ = triggersLock.withLock { triggers.removeValue(forKey: token) }
    }

    public final func testTrigger(_ token: QueueTriggerToken) -> Bool {
        let trigger = triggersLock.withLock { triggers[token] }
        guard let trigger else { return false }
        let snapshot = makeSnapshot()
        return evaluate(
            condition: trigger.condition, snapshot: snapshot,
            refMinPTS: trigger.referenceMinPTS, refMaxPTS: trigger.referenceMaxPTS
        )
    }

    public final func evaluateTriggers() {
        triggersLock.lock()
        guard !triggers.isEmpty else { triggersLock.unlock(); return }
        let snapshot = makeSnapshot()
        var toFire: [(QueueTriggerToken, (QueueTriggerToken) -> Void)] = []

        for token in Array(triggers.keys) {
            guard var trigger = triggers[token] else { continue }
            guard case .whenReset = trigger.condition else {
                let newResult = evaluate(
                    condition: trigger.condition, snapshot: snapshot,
                    refMinPTS: trigger.referenceMinPTS, refMaxPTS: trigger.referenceMaxPTS
                )

                if newResult && !trigger.lastResult {
                    // false → true transition: schedule callback and re-arm
                    // "changes" triggers by snapshotting the new reference values.
                    if let body = trigger.body { toFire.append((trigger.token, body)) }
                    trigger.referenceMinPTS = snapshot.minPTS
                    trigger.referenceMaxPTS = snapshot.maxPTS
                }

                trigger.lastResult = newResult
                triggers[token] = trigger
                continue
            }
        }
        triggersLock.unlock()

        toFire.forEach { $0.1($0.0) }
    }

    public final func fireResetTriggers() {
        var toFire: [(QueueTriggerToken, (QueueTriggerToken) -> Void)] = []
        triggersLock.lock()
        for trigger in triggers.values {
            guard case .whenReset = trigger.condition else { continue }
            if let body = trigger.body { toFire.append((trigger.token, body)) }
        }
        triggersLock.unlock()
        toFire.forEach { $0.1($0.0) }
    }

    public func getLargestQueuedTimestamp() -> CMTime {
        fatalError("To override")
    }

    private func makeSnapshot() -> Snapshot {
        let maxQueued = getLargestQueuedTimestamp()
        return Snapshot(
            aheadDuration: bufferedAheadDuration,
            sampleCount: readableSampleCount,
            minPTS: minReadableTimestamp,
            maxPTS: maxQueued == .negativeInfinity ? nil : maxQueued,
            hasData: hasReadableSamples,
            isEndOfData: isEndOfData
        )
    }

    private func evaluate(
        condition: TriggerCondition, snapshot: Snapshot,
        refMinPTS: CMTime?, refMaxPTS: CMTime?
    ) -> Bool {
        switch condition {
        case let .whenDurationBecomesLessThan(t):
            snapshot.aheadDuration < t
        case let .whenDurationBecomesLessThanOrEqualTo(t):
            snapshot.aheadDuration <= t
        case let .whenDurationBecomesGreaterThan(t):
            snapshot.aheadDuration > t
        case let .whenDurationBecomesGreaterThanOrEqualTo(t):
            snapshot.aheadDuration >= t
        case .whenMinPresentationTimeStampChanges:
            snapshot.minPTS != refMinPTS
        case .whenMaxPresentationTimeStampChanges:
            snapshot.maxPTS != refMaxPTS
        case let .whenMaxPresentationTimeStampBecomesGreaterThanOrEqualTo(t):
            snapshot.maxPTS.map { $0 >= t } ?? false
        case .whenDataBecomesReady:
//            print("ℹ️ IS READY = \(snapshot.hasData)")
            snapshot.hasData
        case .whenEndOfDataReached:
            snapshot.isEndOfData
        case let .whenBufferCountBecomesLessThan(n):
            snapshot.sampleCount < n
        case let .whenBufferCountBecomesGreaterThan(n):
            snapshot.sampleCount > n
        case .whenReset:
            false
        @unknown default:
            false
        }
    }
}

private extension TriggerableQueue {
    private struct InstalledTrigger {
        let token: QueueTriggerToken
        let condition: TriggerCondition
        let body: ((QueueTriggerToken) -> Void)?
        var lastResult: Bool
        var referenceMinPTS: CMTime?
        var referenceMaxPTS: CMTime?
    }

    private struct Snapshot {
        let aheadDuration: CMTime
        let sampleCount: Int
        let minPTS: CMTime?
        let maxPTS: CMTime?
        let hasData: Bool
        let isEndOfData: Bool
    }
}
