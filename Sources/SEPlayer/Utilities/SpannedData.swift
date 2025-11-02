//
//  SpannedData.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.10.2025.
//

struct SpannedData<Value> {
    typealias RemoveCallback = (Value) -> Void

    private var keys: [Int] = []
    private var values: [Value] = []
    private var memoizedReadIndex: Int? = nil
    private let removeCallback: RemoveCallback

    public init(removeCallback: @escaping RemoveCallback) {
        self.removeCallback = removeCallback
    }

    public mutating func get(_ key: Int) -> Value {
        var memoizedReadIndex = memoizedReadIndex ?? .zero
        defer { self.memoizedReadIndex = memoizedReadIndex }

        while memoizedReadIndex > 0, key < keys[memoizedReadIndex] {
            memoizedReadIndex = memoizedReadIndex - 1
        }

        while memoizedReadIndex < keys.count - 1, key >= keys[memoizedReadIndex + 1] {
            memoizedReadIndex = memoizedReadIndex + 1
        }

        return values[memoizedReadIndex]
    }

    public mutating func appendSpan(startKey: Int, value: Value) {
        var memoizedReadIndex = memoizedReadIndex ?? .zero
        defer { self.memoizedReadIndex = memoizedReadIndex }

        if let lastKey = keys.last {
            if startKey == lastKey {
                removeCallback(values[values.endIndex - 1])
                values[values.endIndex - 1] = value
                return
            }
        }

        keys.append(startKey)
        values.append(value)
    }

    public func getEndValue() -> Value {
        return values[values.endIndex - 1]
    }

    public mutating func discard(to discardToKey: Int) {
        while keys.count > 1, discardToKey >= keys[1] {
            let removed = values.removeFirst()
            keys.removeFirst()
            removeCallback(removed)

            if let index = memoizedReadIndex, index > 0 {
                memoizedReadIndex = index - 1
            }
        }
    }

    public mutating func discard(from discardFromKey: Int) {
        while let lastKey = keys.last, discardFromKey < lastKey {
            let removed = values.removeLast()
            keys.removeLast()
            removeCallback(removed)
        }
        if keys.isEmpty {
            memoizedReadIndex = nil
        } else if let index = memoizedReadIndex {
            memoizedReadIndex = min(index, keys.count - 1)
        }
    }

    public mutating func clear() {
        for v in values {
            removeCallback(v)
        }
        keys.removeAll(keepingCapacity: false)
        values.removeAll(keepingCapacity: false)
        memoizedReadIndex = nil
    }

    public var isEmpty: Bool {
        keys.isEmpty
    }
}
