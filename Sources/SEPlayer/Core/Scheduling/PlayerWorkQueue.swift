//
//  PlayerWorkQueue.swift
//  SEPlayer
//
//  Created by tvrrp on 22.10.2026.
//

import Dispatch
import SEPlayerCommon

/// A serial queue of the player's work, with urgent work and a coalesced update.
///
/// - Work runs in the order it is posted, and never inline: posted while work runs, it runs after it.
/// - Urgent work runs before any work that hasn't started yet.
/// - The update, ``onUpdate``, runs once however often it is requested before it runs.
/// - Once invalidated, nothing more runs.
///
/// Posting works from any thread.
final class PlayerWorkQueue: @unchecked Sendable {
    /// The update. Set once, before any is requested.
    var onUpdate: (() -> Void)?

    private let scheduler: PlayerScheduler
    private let lock = UnfairLock()

    /// Guarded by `lock`.
    private var urgentWork: [() -> Void] = []
    /// Identifies the update request that is allowed to run. Cancelling the pending update, or running it, changes
    /// the identifier, so an update that was posted before does nothing when its turn comes.
    private var currentUpdateRequestId: UInt64 = 0
    private var isUpdateRequested = false
    private var delayedUpdateRequest: DispatchWorkItem?
    private var isInvalidated = false

    init(scheduler: PlayerScheduler) {
        self.scheduler = scheduler
    }

    /// Runs `work` after the work posted before it.
    func post(_ work: @escaping () -> Void) {
        scheduler.post { [weak self] in self?.run(work) }
    }

    /// Runs `work` once `delay` has passed, unless the returned item is cancelled first.
    @discardableResult
    func post(after delay: DispatchTimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        scheduler.post(after: delay) { [weak self] in self?.run(work) }
    }

    /// Runs `work` before any posted work that hasn't started yet.
    func postUrgent(_ work: @escaping () -> Void) {
        lock.withLock { urgentWork.append(work) }
        scheduler.post { [weak self] in self?.runUrgentWork() }
    }

    /// Runs the update after the work posted so far, unless one is already requested.
    func requestUpdate() {
        let requestId: UInt64? = lock.withLock {
            guard !isUpdateRequested, !isInvalidated else { return nil }

            isUpdateRequested = true
            return currentUpdateRequestId
        }
        guard let requestId else { return }

        scheduler.post { [weak self] in self?.runUpdate(requestId: requestId) }
    }

    /// Requests the update once `delay` has passed, unless an update runs or is cancelled before.
    func requestUpdate(after delay: DispatchTimeInterval) {
        let newRequest = scheduler.post(after: delay) { [weak self] in self?.requestUpdate() }
        let replacedRequest: DispatchWorkItem? = lock.withLock {
            guard !isInvalidated else { return newRequest }

            let replacedRequest = delayedUpdateRequest
            delayedUpdateRequest = newRequest
            return replacedRequest
        }
        replacedRequest?.cancel()
    }

    /// Drops the requested update and the delayed one. An update requested afterwards runs after the work posted
    /// until then.
    func cancelPendingUpdates() {
        let delayedRequest: DispatchWorkItem? = lock.withLock {
            currentUpdateRequestId &+= 1
            isUpdateRequested = false

            let delayedRequest = delayedUpdateRequest
            delayedUpdateRequest = nil
            return delayedRequest
        }
        delayedRequest?.cancel()
    }

    /// Stops running anything, posted already or later.
    func invalidate() {
        let delayedRequest: DispatchWorkItem? = lock.withLock {
            isInvalidated = true
            urgentWork.removeAll()

            let delayedRequest = delayedUpdateRequest
            delayedUpdateRequest = nil
            return delayedRequest
        }
        delayedRequest?.cancel()
    }

    private func run(_ work: () -> Void) {
        runUrgentWork()

        let isInvalidated = lock.withLock { self.isInvalidated }
        guard !isInvalidated else { return }

        work()
    }

    private func runUrgentWork() {
        while let work = nextUrgentWork() {
            work()
        }
    }

    private func nextUrgentWork() -> (() -> Void)? {
        lock.withLock {
            guard !isInvalidated, !urgentWork.isEmpty else { return nil }

            return urgentWork.removeFirst()
        }
    }

    private func runUpdate(requestId: UInt64) {
        runUrgentWork()

        let isCurrentRequest = lock.withLock { !isInvalidated && requestId == currentUpdateRequestId }
        guard isCurrentRequest else { return }

        cancelPendingUpdates()
        onUpdate?()
    }
}
