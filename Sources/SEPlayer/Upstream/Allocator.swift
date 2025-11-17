//
//  Allocator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import BasicContainers
import Foundation

public protocol AllocationNode: AnyObject {
    func consumeAllocation() -> Allocation?
    func next() -> AllocationNode?
}

public protocol Allocator: AnyObject, Sendable {
    var totalBytesAllocated: Int { get }
    var individualAllocationSize: Int { get }
    func allocate() -> Allocation
    func release(allocation: consuming Allocation)
    func release(allocationNode: AllocationNode)
    func trim()
}

final class DefaultAllocator: Allocator, @unchecked Sendable {
    var totalBytesAllocated: Int {
        lock.withLock { return allocatedCount * individualAllocationSize }
    }

    let individualAllocationSize: Int

    private let trimOnReset: Bool
    private let lock: UnfairLock

    private var allocatedCount = 0
    private var availableCount = 0
    private var targetBufferSize = 0

    private var availableAllocations: UniqueArray<Allocation?>

    init(
        trimOnReset: Bool = true,
        individualAllocationSize: Int = Int(2 * getpagesize()),
        initialAllocationCount: Int = 0
    ) {
        self.trimOnReset = trimOnReset
        self.individualAllocationSize = individualAllocationSize
        self.lock = UnfairLock()

        let capacity = initialAllocationCount + .availableExtraCapacity
        availableAllocations = UniqueArray(capacity: capacity)
        for _ in 0..<capacity { availableAllocations.append(nil) }
    }

    func reset() {
        if trimOnReset {
            setTargetBufferSize(new: 0)
        }
    }

    func setTargetBufferSize(new targetBufferSize: Int) {
        lock.lock()
        let didReduceBufferSize = targetBufferSize < self.targetBufferSize
        self.targetBufferSize = targetBufferSize
        lock.unlock()
        if didReduceBufferSize {
            trim()
        }
    }

    func allocate() -> Allocation {
        lock.lock(); defer { lock.unlock() }
        allocatedCount += 1

        let allocation: Allocation
        if availableCount > 0 {
            availableCount -= 1
            allocation = availableAllocations[availableCount].take()!
        } else {
            allocation = Allocation(capacity: individualAllocationSize)
            if allocatedCount > availableAllocations.count {
                for _ in 0..<availableAllocations.count { availableAllocations.append(nil) }
            }
        }

        return allocation
    }

    func release(allocation: consuming Allocation) {
        lock.lock(); defer { lock.unlock() }
        availableAllocations[availableCount] = consume allocation
        availableCount += 1
        allocatedCount -= 1
    }

    func release(allocationNode: AllocationNode) {
        lock.lock(); defer { lock.unlock() }
        var allocationNode: AllocationNode? = allocationNode
        while let allocationNodeToClear = allocationNode {
            availableAllocations[availableCount] = allocationNodeToClear.consumeAllocation()
            availableCount += 1
            allocatedCount -= 1
            allocationNode = allocationNodeToClear.next()
        }
    }

    func trim() {
        lock.lock(); defer { lock.unlock() }
        let targetAllocationCount = (targetBufferSize + individualAllocationSize - 1) / individualAllocationSize
        let targetAvailableCount = max(0, targetAllocationCount - allocatedCount)
        guard targetAvailableCount < availableCount else { return }

        var newArray = RigidArray<Allocation?>(capacity: (targetAvailableCount..<availableCount).count)
        for _ in targetAvailableCount..<availableCount { newArray.append(nil) }
        availableAllocations.replaceSubrange(targetAvailableCount..<availableCount, consuming: newArray)
    }
}

private extension Int {
    static let availableExtraCapacity: Int = 100
}
