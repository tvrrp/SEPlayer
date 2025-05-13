//
//  Allocator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import unistd
import Darwin

protocol AllocationNode: AnyObject {
    func getAllocation() -> Allocation
    func next() -> AllocationNode?
}

protocol Allocator: AnyObject {
    var totalBytesAllocated: Int { get }
    var individualAllocationSize: Int { get }
    func allocate() -> Allocation
    func release(allocation: Allocation)
    func release(allocationNode: AllocationNode)
    func trim()
}

final class DefaultAllocator: Allocator {
    var totalBytesAllocated: Int {
        assert(queue.isCurrent())
        return allocatedCount * _individualAllocationSize
    }

    var individualAllocationSize: Int {
        assert(queue.isCurrent())
        return _individualAllocationSize
    }

    private let queue: Queue
    private let trimOnReset: Bool
    private let _individualAllocationSize: Int

    private var allocatedCount = 0
    private var availableCount = 0
    private var targetBufferSize = 0

    private var availableAllocations: [Allocation] = []

    init(
        queue: Queue,
        trimOnReset: Bool = true,
        individualAllocationSize: Int = Int(2 * getpagesize()),
        initialAllocationCount: Int = 0
    ) {
        self.queue = queue
        self.trimOnReset = trimOnReset
        self._individualAllocationSize = malloc_good_size(individualAllocationSize)
    }

    func reset() {
        assert(queue.isCurrent())
        if trimOnReset {
            setTargetBufferSize(new: 0)
        }
    }

    func setTargetBufferSize(new targetBufferSize: Int) {
        assert(queue.isCurrent())
        let didReduceBufferSize = targetBufferSize < self.targetBufferSize
        self.targetBufferSize = targetBufferSize
        if didReduceBufferSize {
            trim()
        }
    }

    func allocate() -> Allocation {
        assert(queue.isCurrent())
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
        assert(queue.isCurrent())
        availableAllocations.append(allocation)
        availableCount += 1
        allocatedCount -= 1
    }

    func release(allocationNode: AllocationNode) {
        assert(queue.isCurrent())
        var allocationNode: AllocationNode? = allocationNode
        while let allocationNodeToClear = allocationNode {
            availableCount += 1
            allocatedCount -= 1
            availableAllocations.append(allocationNodeToClear.getAllocation())
            allocationNode = allocationNodeToClear.next()
        }
    }

    func trim() {
        assert(queue.isCurrent())
        let targetAllocationCount = (targetBufferSize + individualAllocationSize - 1) / individualAllocationSize
        let targetAvailableCount = max(0, targetAllocationCount - allocatedCount)
        guard targetAvailableCount < availableCount else { return }

        if targetAvailableCount == 0 {
            availableAllocations.removeAll(keepingCapacity: true)
        }
        availableAllocations.removeSubrange(targetAvailableCount..<availableCount)
    }
}
