//
//  FakeShuffleOrder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.11.2025.
//

@testable import SEPlayer

struct FakeShuffleOrder: ShuffleOrder {
    let count: Int
    var lastIndex: Int? { count > 0 ? 0 : nil }
    var firstIndex: Int? { count > 0 ? count - 1 : nil }

    func nextIndex(index: Int) -> Int? {
        index > 0 ? index - 1 : nil
    }

    func previousIndex(index: Int) -> Int? {
        index < count - 1 ? index + 1 : nil
    }

    func cloneAndInsert(insertionIndex: Int, insertionCount: Int) -> ShuffleOrder {
        FakeShuffleOrder(count: count + insertionCount)
    }

    func cloneAndRemove(indexFrom: Int, indexToExclusive: Int) -> ShuffleOrder {
        FakeShuffleOrder(count: count - indexToExclusive + indexFrom)
    }

    func cloneAndClear() -> ShuffleOrder {
        FakeShuffleOrder(count: 0)
    }
}
