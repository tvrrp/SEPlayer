//
//  TriggerableSampleQueue.swift
//  SEPlayer
//
//  Created by tvrrp on 15.03.2026.
//

import CoreMedia
import Decoder
import SEPlayerCommon

class TriggerableSampleQueue: SampleQueue {
    private let triggersLock = UnfairLock()
    private var triggers: [QueueTriggerToken: InstalledTrigger] = [:]

    @discardableResult
    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)? = nil) -> QueueTriggerToken {
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

    func removeTrigger(_ token: QueueTriggerToken) {
        triggersLock.withLock { triggers.removeValue(forKey: token) }
    }

    func testTrigger(_ token: QueueTriggerToken) -> Bool {
        let trigger = triggersLock.withLock { triggers[token] }
        guard let trigger else { return false }
        let snapshot = makeSnapshot()
        return evaluate(
            condition: trigger.condition, snapshot: snapshot,
            refMinPTS: trigger.referenceMinPTS, refMaxPTS: trigger.referenceMaxPTS
        )
    }

    override func sampleMetadata(
        time: CMSampleTimingInfo, flags: SampleFlags, size: Int, offset: Int,
        isolation: isolated any Actor
    ) {
        super.sampleMetadata(time: time, flags: flags, size: size, offset: offset, isolation: isolation)
//        print("ℹ️ SAMPLE MEDATADA, time = \(time)")
        evaluateTriggers()
    }

    override func read(
        buffer: DecoderInputBuffer, readFlags: ReadFlags, loadingFinished: Bool
    ) throws -> SampleStreamReadResult {
        let result = try super.read(buffer: buffer, readFlags: readFlags, loadingFinished: loadingFinished)
        if result == .didReadBuffer { evaluateTriggers() }
        return result
    }

    override func seek(to sampleIndex: Int) -> Bool {
        let moved = super.seek(to: sampleIndex)
        if moved { evaluateTriggers() }
        return moved
    }

    override func seek(time toTime: CMTime, allowTimeBeyondBuffer: Bool) -> Bool {
        let moved = super.seek(time: toTime, allowTimeBeyondBuffer: allowTimeBeyondBuffer)
        if moved { evaluateTriggers() }
        return moved
    }

    override func reset(resetUpstreamFormat: Bool) {
        super.reset(resetUpstreamFormat: resetUpstreamFormat)
        fireResetTriggers()
        evaluateTriggers()
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
        case .whenDurationBecomesLessThan(let t):
            return snapshot.aheadDuration < t
        case .whenDurationBecomesLessThanOrEqualTo(let t):
            return snapshot.aheadDuration <= t
        case .whenDurationBecomesGreaterThan(let t):
            return snapshot.aheadDuration > t
        case .whenDurationBecomesGreaterThanOrEqualTo(let t):
            return snapshot.aheadDuration >= t
        case .whenMinPresentationTimeStampChanges:
            return snapshot.minPTS != refMinPTS
        case .whenMaxPresentationTimeStampChanges:
            return snapshot.maxPTS != refMaxPTS
        case .whenDataBecomesReady:
//            print("ℹ️ IS READY = \(snapshot.hasData)")
            return snapshot.hasData
        case .whenEndOfDataReached:
            return snapshot.isEndOfData
        case .whenBufferCountBecomesLessThan(let n):
            return snapshot.sampleCount < n
        case .whenBufferCountBecomesGreaterThan(let n):
            return snapshot.sampleCount > n
        case .whenReset:
            return false
        }
    }

    private func evaluateTriggers() {
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

//        print("ℹ️ WILL REACH TRIGGERS. COUNT = \(toFire.count)")
        toFire.forEach { $0.1($0.0) }
    }

    private func fireResetTriggers() {
        var toFire: [(QueueTriggerToken, (QueueTriggerToken) -> Void)] = []
        triggersLock.lock()
        for trigger in triggers.values {
            guard case .whenReset = trigger.condition else { continue }
            if let body = trigger.body { toFire.append((trigger.token, body)) }
        }
        triggersLock.unlock()
        toFire.forEach { $0.1($0.0) }
    }
}

private extension TriggerableSampleQueue {
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
