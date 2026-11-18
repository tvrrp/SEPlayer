//
//  PlayerScheduler.swift
//  SEPlayer
//
//  Created by tvrrp on 22.10.2026.
//

import Dispatch
import SEPlayerCommon

/// Runs work on the player's queue. Work never runs inline: posted from the queue itself, it runs after the work
/// running now.
public protocol PlayerScheduler: AnyObject, Sendable {
    /// Runs `work` after everything posted before it.
    func post(_ work: @escaping @Sendable () -> Void)
    /// Runs `work` once `delay` has passed, unless the returned item is cancelled first.
    func post(after delay: DispatchTimeInterval, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem
}

/// Posts to the dispatch queue of the player.
final class DispatchPlayerScheduler: PlayerScheduler {
    private let queue: Queue

    init(queue: Queue) {
        self.queue = queue
    }

    func post(_ work: @escaping @Sendable () -> Void) {
        queue.justDispatch(work)
    }

    func post(after delay: DispatchTimeInterval, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        queue.queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}
