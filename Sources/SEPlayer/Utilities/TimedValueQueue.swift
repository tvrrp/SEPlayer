//
//  TimedValueQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import Darwin

final class TimedValueQueue<Element> {
    var size: Int {
        get { withLock { elements.count } }
    }

    private var elements: [(timestamp: Int64, value: Element)] = []

    init(initialBufferSize: Int = 10) {
        elements.reserveCapacity(max(1, initialBufferSize))
    }

    func add(timestamp: Int64, value: Element) {
        withLock {
            if let last = elements.last, timestamp <= last.timestamp {
                clear()
            }
            elements.append((timestamp, value))
        }
    }

    func clear() {
        withLock { elements.removeAll(keepingCapacity: true) }
    }

    func pollFirst() -> Element? {
        return withLock { elements.isEmpty ? nil : elements.removeFirst().value }
    }

    func pollFloor(timestamp: Int64) -> Element? {
        return withLock { pool(timestamp: timestamp, onlyOlder: true) }
    }

    func pool(timestamp: Int64) -> Element? {
        return withLock { pool(timestamp: timestamp, onlyOlder: false) }
    }

    private func pool(timestamp: Int64, onlyOlder: Bool) -> Element? {
        var result: Element? = nil
        var previousDiff = Int64.max
        while !elements.isEmpty {
            let currentDiff = timestamp - elements[0].timestamp
            if currentDiff < 0, (onlyOlder || -currentDiff >= previousDiff) {
                break
            }
            previousDiff = currentDiff
            result = elements.removeFirst().value
        }
        return result
    }

    private func withLock<T>(_ action: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfairLock)
        let value = try action()
        os_unfair_lock_unlock(&unfairLock)
        return value
    }

    private var unfairLock = os_unfair_lock_s()
}
