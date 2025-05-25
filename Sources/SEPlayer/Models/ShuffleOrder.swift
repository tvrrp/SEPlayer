//
//  ShuffleOrder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 20.05.2025.
//

public protocol ShuffleOrder {
    var count: Int { get }
    var lastIndex: Int? { get }
    var firstIndex: Int? { get }
    func nextIndex(index: Int) -> Int?
    func previousIndex(index: Int) -> Int?
    func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder // TODO: replace with Range<Int>
    func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder // TODO: replace with Range<Int>
    func cloneAndClear() -> ShuffleOrder
}

struct DefaultShuffleOrder: ShuffleOrder {
    var count: Int { shuffled.count }

    var lastIndex: Int? {
        shuffled.count > 0 ? shuffled[shuffled.count - 1] : nil
    }

    var firstIndex: Int? {
        return shuffled.count > 0 ? shuffled[0] : nil
    }

    private let shuffled: [Int]
    private let indexInShuffled: [Int]

    init(length: Int) {
        var shuffled = [Int](repeating: 0, count: length)
        for i in 0..<length {
            let swapIndex = Int.random(in: 0...i)
            shuffled[i] = shuffled[swapIndex]
            shuffled[swapIndex] = i
        }
        self.init(shuffled: shuffled)
    }

    init(shuffled: [Int]) {
        self.shuffled = shuffled
        self.indexInShuffled = shuffled
    }

    func nextIndex(index: Int) -> Int? {
        let shuffledIndex = indexInShuffled[index] + 1
        return shuffledIndex < shuffled.count ? shuffled[shuffledIndex] : nil
    }

    func previousIndex(index: Int) -> Int? {
        let shuffledIndex = indexInShuffled[index] - 1
        return shuffledIndex >= 0 ? shuffled[shuffledIndex] : nil
    }

    func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder {
        var insertionPoints = (0..<insertionCount).map { _ in Int.random(in: 0...shuffled.count) }
        var insertionValues = [Int](repeating: 0, count: insertionCount)

        for i in 0..<insertionCount {
            let swapIndex = Int.random(in: 0...i)
            insertionValues[i] = insertionValues[swapIndex]
            insertionValues[swapIndex] = i + insertionIndex
        }

        insertionPoints.sort()

        var newShuffled = [Int]()
        var oldIndex = 0
        var insertionIndexPointer = 0

        for _ in 0..<(shuffled.count + insertionCount) {
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

    func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder {
        let removeCount = indexToExclusive - indexFrom
        var newShuffled = [Int]()

        for value in shuffled {
            if value < indexFrom || value >= indexToExclusive {
                newShuffled.append(value >= indexFrom ? value - removeCount : value)
            }
        }

        return DefaultShuffleOrder(shuffled: newShuffled)
    }

    func cloneAndClear() -> any ShuffleOrder {
        DefaultShuffleOrder(length: .zero)
    }
}

struct UnshuffledShuffleOrder: ShuffleOrder {
    let count: Int

    var lastIndex: Int? {
        count > 0 ? count - 1 : nil
    }

    var firstIndex: Int? {
        count > 0 ? 0 : nil
    }

    func nextIndex(index: Int) -> Int? {
        index + 1 < count ? index : nil
    }

    func previousIndex(index: Int) -> Int? {
        index - 1 >= 0 ? index : nil
    }

    func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder {
        UnshuffledShuffleOrder(count: count + insertionCount)
    }

    func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder {
        UnshuffledShuffleOrder(count: count - indexToExclusive + indexFrom)
    }

    func cloneAndClear() -> ShuffleOrder {
        UnshuffledShuffleOrder(count: .zero)
    }
}
