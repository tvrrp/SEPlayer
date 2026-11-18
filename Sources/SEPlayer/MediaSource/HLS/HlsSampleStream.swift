//
//  HlsSampleStream.swift
//  SEPlayer
//

import CoreMedia
import Foundation
import SEPlayerCommon

/// The ``SampleStream`` of a track group of an ``HlsSampleStreamWrapper``.
///
/// A wrapper prepared from the multivariant playlist alone has track groups before it has sample queues. Until
/// they are mapped, the stream has nothing to read, and the triggers installed on it wait to be installed on its
/// sample queue.
final class HlsSampleStream: SampleStream {
    let trackGroupIndex: Int

    /// The sample queue the stream reads, once bound.
    var boundSampleQueueIndex: Int? {
        lock.withLock {
            if case let .bound(index) = binding { index } else { nil }
        }
    }

    var bufferedAheadDuration: CMTime {
        guard let index = resolveSampleQueueIndex() else { return .zero }
        return wrapper.bufferedAheadDuration(sampleQueueIndex: index)
    }

    private let wrapper: HlsSampleStreamWrapper
    private let lock = UnfairLock()
    // All guarded by lock.
    private var binding: HlsSampleStreamWrapper.SampleQueueBinding = .pending
    private var pendingTriggers: [QueueTriggerToken: PendingTrigger] = [:]
    /// The tokens the sample queue gave for triggers installed on the stream.
    private var queueTokens: [QueueTriggerToken: QueueTriggerToken] = [:]
    private var requiresFormat = false

    init(wrapper: HlsSampleStreamWrapper, trackGroupIndex: Int) {
        self.wrapper = wrapper
        self.trackGroupIndex = trackGroupIndex
    }

    func isReady() -> Bool {
        guard let index = resolveSampleQueueIndex() else { return false }
        return wrapper.isReady(sampleQueueIndex: index)
    }

    func maybeThrowError() throws {
        if case .noMapping = lock.withLock({ binding }) {
            throw ParserError.createForMalformedManifest(
                message: "Unable to bind a sample queue to track group \(trackGroupIndex)."
            )
        }
        try wrapper.maybeThrowError()
    }

    func readData(readFlags: ReadFlags) throws -> SampleStreamReadResult {
        guard let index = resolveSampleQueueIndex() else { return .nothingRead }
        let flags = lock.withLock { requiresFormat ? readFlags.union(.requireFormat) : readFlags }
        let result = try wrapper.readData(sampleQueueIndex: index, readFlags: flags)
        if case .didReadFormat = result { lock.withLock { requiresFormat = false } }
        return result
    }

    func skipData(position: CMTime) throws -> Int {
        guard let index = resolveSampleQueueIndex() else { return 0 }
        return wrapper.skipData(sampleQueueIndex: index, position: position)
    }

    func seekWithinBuffer(to position: CMTime) throws -> SampleStreamSeekResult {
        guard let index = resolveSampleQueueIndex() else { return .unavailable }
        let result = wrapper.seekWithinBuffer(sampleQueueIndex: index, position: position)
        if case .success = result { lock.withLock { requiresFormat = true } }
        return result
    }

    // MARK: - Triggers

    @discardableResult
    func installTrigger(condition: TriggerCondition, _ body: ((QueueTriggerToken) -> Void)?) -> QueueTriggerToken {
        let token = QueueTriggerToken()
        if let index = resolveSampleQueueIndex() {
            install(token: token, condition: condition, body: body, sampleQueueIndex: index)
        } else {
            lock.withLock { pendingTriggers[token] = PendingTrigger(condition: condition, body: body) }
            // The mapping may have come in meanwhile.
            sampleQueuesDidMap()
        }
        return token
    }

    func removeTrigger(_ token: QueueTriggerToken) {
        let (queueToken, index) = lock.withLock { () -> (QueueTriggerToken?, Int?) in
            pendingTriggers.removeValue(forKey: token)
            let index: Int? = if case let .bound(index) = binding { index } else { nil }
            return (queueTokens.removeValue(forKey: token), index)
        }
        if let queueToken, let index {
            wrapper.sampleQueue(at: index).removeTrigger(queueToken)
        }
    }

    func testTrigger(_ token: QueueTriggerToken) -> Bool {
        let (queueToken, index) = lock.withLock { () -> (QueueTriggerToken?, Int?) in
            let index: Int? = if case let .bound(index) = binding { index } else { nil }
            return (queueTokens[token], index)
        }
        guard let queueToken, let index else { return false }
        return wrapper.sampleQueue(at: index).testTrigger(queueToken)
    }

    /// Called once the wrapper mapped its sample queues: waiting triggers go to the sample queue.
    func sampleQueuesDidMap() {
        guard let index = resolveSampleQueueIndex() else { return }
        let triggers = lock.withLock { () -> [QueueTriggerToken: PendingTrigger] in
            defer { pendingTriggers.removeAll() }
            return pendingTriggers
        }
        for (token, trigger) in triggers {
            install(token: token, condition: trigger.condition, body: trigger.body, sampleQueueIndex: index)
        }
    }

    // MARK: - Private

    private func resolveSampleQueueIndex() -> Int? {
        let current = lock.withLock { binding }
        switch current {
        case let .bound(index):
            return index
        case .noMapping:
            return nil
        case .pending:
            let resolved = wrapper.bindSampleQueue(trackGroupIndex: trackGroupIndex)
            lock.withLock { binding = resolved }
            if case let .bound(index) = resolved { return index }
            return nil
        }
    }

    private func install(
        token: QueueTriggerToken,
        condition: TriggerCondition,
        body: ((QueueTriggerToken) -> Void)?,
        sampleQueueIndex: Int
    ) {
        let queueToken = wrapper.sampleQueue(at: sampleQueueIndex).installTrigger(condition: condition) { _ in
            body?(token)
        }
        lock.withLock { queueTokens[token] = queueToken }
    }

    private struct PendingTrigger {
        let condition: TriggerCondition
        let body: ((QueueTriggerToken) -> Void)?
    }
}
