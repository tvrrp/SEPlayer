//
//  TimedValueQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//

import Darwin

final class TimedValueQueue<Element> {
    var size: Int {
        get { unfairLock.withLock { elements.count } }
    }

    private var elements: [(timestamp: Int64, value: Element)] = []

    init(initialBufferSize: Int = 10) {
        elements.reserveCapacity(max(1, initialBufferSize))
    }

    func add(timestamp: Int64, value: Element) {
        unfairLock.withLock {
            if let last = elements.last, timestamp <= last.timestamp {
                clear()
            }
            elements.append((timestamp, value))
        }
    }

    func clear() {
        unfairLock.withLock { elements.removeAll(keepingCapacity: true) }
    }

    func pollFirst() -> Element? {
        return unfairLock.withLock { elements.isEmpty ? nil : elements.removeFirst().value }
    }

    func pollFloor(timestamp: Int64) -> Element? {
        return unfairLock.withLock { pool(timestamp: timestamp, onlyOlder: true) }
    }

    func pool(timestamp: Int64) -> Element? {
        return unfairLock.withLock { pool(timestamp: timestamp, onlyOlder: false) }
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

    private var unfairLock = UnfairLock()
}
