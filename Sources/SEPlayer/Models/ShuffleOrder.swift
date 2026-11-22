//
//  ShuffleOrder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.ShuffleOrder
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

/// The order the items of a playlist play in when shuffling is on.
public protocol ShuffleOrder: Sendable {
    var count: Int { get }
    var lastIndex: Int? { get }
    var firstIndex: Int? { get }
    func nextIndex(index: Int) -> Int?
    func previousIndex(index: Int) -> Int?
    func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder // TODO: replace with Range<Int>
    func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder // TODO: replace with Range<Int>
    func cloneAndClear() -> ShuffleOrder
}

/// A ``ShuffleOrder`` in random order, which inserted items join at random places.
public struct DefaultShuffleOrder: ShuffleOrder {
    public var count: Int { shuffled.count }

    public var lastIndex: Int? {
        shuffled.count > 0 ? shuffled[shuffled.count - 1] : nil
    }

    public var firstIndex: Int? {
        shuffled.count > 0 ? shuffled[0] : nil
    }

    private let shuffled: [Int]
    private let indexInShuffled: [Int]

    /// A random order of `length` items.
    public init(length: Int) {
        var shuffled = [Int](repeating: 0, count: length)
        for i in 0 ..< length {
            let swapIndex = Int.random(in: 0 ... i)
            shuffled[i] = shuffled[swapIndex]
            shuffled[swapIndex] = i
        }
        self.init(shuffled: shuffled)
    }

    /// The order `shuffled`: the indices of the items, each once, in the order they play.
    public init(shuffled: [Int]) {
        var indexInShuffled = [Int](repeating: 0, count: shuffled.count)
        for (position, index) in shuffled.enumerated() {
            indexInShuffled[index] = position
        }
        self.shuffled = shuffled
        self.indexInShuffled = indexInShuffled
    }

    public func nextIndex(index: Int) -> Int? {
        let shuffledIndex = indexInShuffled[index] + 1
        return shuffledIndex < shuffled.count ? shuffled[shuffledIndex] : nil
    }

    public func previousIndex(index: Int) -> Int? {
        let shuffledIndex = indexInShuffled[index] - 1
        return shuffledIndex >= 0 ? shuffled[shuffledIndex] : nil
    }

    public func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder {
        var insertionPoints = (0 ..< insertionCount).map { _ in Int.random(in: 0 ... shuffled.count) }
        var insertionValues = [Int](repeating: 0, count: insertionCount)

        for i in 0 ..< insertionCount {
            let swapIndex = Int.random(in: 0 ... i)
            insertionValues[i] = insertionValues[swapIndex]
            insertionValues[swapIndex] = i + insertionIndex
        }

        insertionPoints.sort()

        var newShuffled = [Int]()
        var oldIndex = 0
        var insertionIndexPointer = 0

        for _ in 0 ..< (shuffled.count + insertionCount) {
            if insertionIndexPointer < insertionCount && oldIndex == insertionPoints[insertionIndexPointer] {
                newShuffled.append(insertionValues[insertionIndexPointer])
                insertionIndexPointer += 1
            } else {
                var value = shuffled[oldIndex]
                oldIndex += 1
                if value >= insertionIndex {
                    value += insertionCount
                }
                newShuffled.append(value)
            }
        }

        return DefaultShuffleOrder(shuffled: newShuffled)
    }

    public func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder {
        let removeCount = indexToExclusive - indexFrom
        var newShuffled = [Int]()

        for value in shuffled {
            if value < indexFrom || value >= indexToExclusive {
                newShuffled.append(value >= indexFrom ? value - removeCount : value)
            }
        }

        return DefaultShuffleOrder(shuffled: newShuffled)
    }

    public func cloneAndClear() -> any ShuffleOrder {
        DefaultShuffleOrder(length: .zero)
    }
}

/// A ``ShuffleOrder`` that keeps the order of the playlist.
public struct UnshuffledShuffleOrder: ShuffleOrder {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var lastIndex: Int? {
        count > 0 ? count - 1 : nil
    }

    public var firstIndex: Int? {
        count > 0 ? 0 : nil
    }

    public func nextIndex(index: Int) -> Int? {
        index + 1 < count ? index : nil
    }

    public func previousIndex(index: Int) -> Int? {
        index - 1 >= 0 ? index : nil
    }

    public func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder {
        UnshuffledShuffleOrder(count: count + insertionCount)
    }

    public func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder {
        UnshuffledShuffleOrder(count: count - indexToExclusive + indexFrom)
    }

    public func cloneAndClear() -> ShuffleOrder {
        UnshuffledShuffleOrder(count: .zero)
    }
}
