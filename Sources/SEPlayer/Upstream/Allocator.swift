//
//  Allocator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import Foundation

public protocol AllocationNode: AnyObject {
    func getAllocation() -> Allocation
    func next() -> AllocationNode?
}

public protocol Allocator: AnyObject, Sendable {
    var totalBytesAllocated: Int { get }
    var individualAllocationSize: Int { get }
    func allocate() -> Allocation
    func release(allocation: Allocation)
    func release(allocationNode: AllocationNode)
    func trim()
}

final class DefaultAllocator: Allocator, @unchecked Sendable {
    var totalBytesAllocated: Int {
        lock.withLock { return allocatedCount * individualAllocationSize }
    }

    let individualAllocationSize: Int

    private let trimOnReset: Bool
    private let lock: NSLock

    private var allocatedCount = 0
    private var availableCount = 0
    private var targetBufferSize = 0

    private var availableAllocations: [Allocation] = []

    init(
        trimOnReset: Bool = true,
        individualAllocationSize: Int = Int(2 * getpagesize()),
        initialAllocationCount: Int = 0
    ) {
        self.trimOnReset = trimOnReset
        self.individualAllocationSize = malloc_good_size(individualAllocationSize)
        self.lock = NSLock()
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
        if availableCount > 0 {
            availableCount -= 1
            return availableAllocations.removeLast()
        } else {
            let ptr = malloc(size_t(individualAllocationSize))!
            ptr.bindMemory(to: UInt8.self, capacity: individualAllocationSize)

            return .init(data: ptr, capacity: individualAllocationSize)
        }
    }

    func release(allocation: Allocation) {
        lock.lock(); defer { lock.unlock() }
        availableAllocations.append(allocation)
        availableCount += 1
        allocatedCount -= 1
    }

    func release(allocationNode: AllocationNode) {
        lock.lock(); defer { lock.unlock() }
        var allocationNode: AllocationNode? = allocationNode
        while let allocationNodeToClear = allocationNode {
            availableCount += 1
            allocatedCount -= 1
            availableAllocations.append(allocationNodeToClear.getAllocation())
            allocationNode = allocationNodeToClear.next()
        }
    }

    func trim() {
        lock.lock(); defer { lock.unlock() }
        let targetAllocationCount = (targetBufferSize + individualAllocationSize - 1) / individualAllocationSize
        let targetAvailableCount = max(0, targetAllocationCount - allocatedCount)
        guard targetAvailableCount < availableCount else { return }

        if targetAvailableCount == 0 {
            availableAllocations.removeAll(keepingCapacity: true)
        }
        availableAllocations.removeSubrange(targetAvailableCount..<availableCount)
    }
}
