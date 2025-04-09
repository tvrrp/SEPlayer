//
//  Allocator.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import unistd

protocol Allocator {
    var totalBytesAllocated: Int { get }
    var individualAllocationSize: Int { get }

    func allocate(capacity: Int) -> Allocation
    func release(allocation: Allocation)
    func trim()
}

final class DefaultAllocator: Allocator {
    var totalBytesAllocated: Int {
        allocatedCount * individualAllocationSize
    }

    let individualAllocationSize: Int

    private let queue: Queue
    private let trimOnReset: Bool
    private let initialAllocationBlock: UnsafeMutableRawBufferPointer?

    private var targetBufferSize: Int
    private var allocatedCount: Int
    private var availableCount: Int
    private var availableAllocations: [Allocation]

    init(queue: Queue, trimOnReset: Bool, initialAllocationCount: Int = 0) {
        self.queue = queue
        self.trimOnReset = trimOnReset
        self.individualAllocationSize = Int(getpagesize())
        self.targetBufferSize = 0
        self.allocatedCount = 0
        self.availableCount = initialAllocationCount
        self.availableAllocations = []
        if initialAllocationCount > 0 {
            let initialAllocationBlock = UnsafeMutableRawBufferPointer.allocateUInt8(
                byteCount: initialAllocationCount * individualAllocationSize
            )
            for i in 0..<initialAllocationCount {
                availableAllocations.append(
                    Allocation(queue: queue, data: initialAllocationBlock, offset: i * individualAllocationSize, size: individualAllocationSize)
                )
            }
            self.initialAllocationBlock = initialAllocationBlock
        } else {
            initialAllocationBlock = nil
        }
    }

    func reset() {
        assert(queue.isCurrent())
        if trimOnReset {
            trim()
        }
    }

    func setTargetBufferSize(_ targetBufferSize: Int) {
        assert(queue.isCurrent())
        let targetBufferSizeReduced = targetBufferSize < self.targetBufferSize
        self.targetBufferSize = targetBufferSize
        if targetBufferSizeReduced { trim() }
    }

    func allocate(capacity: Int) -> Allocation {
        assert(queue.isCurrent())
        let allocation: Allocation

//        if capacity <= individualAllocationSize && availableCount > 0 {
//            availableCount -= 1
//            allocation = availableAllocations.removeLast()
//        } else {
//            let size = max(capacity, individualAllocationSize)
//            allocation = Allocation(
//                queue: queue,
//                data: UnsafeMutableRawBufferPointer.allocateUInt8(byteCount: size),
//                size: size
//            )
//
//            if allocatedCount > availableAllocations.count {
//                availableAllocations.reserveCapacity(availableAllocations.count * 2)
//            }
//        }
        let size = capacity
        allocation = Allocation(
            queue: queue,
            data: UnsafeMutableRawBufferPointer.allocateUInt8(byteCount: size),
            size: size
        )

        return allocation
    }

    func release(allocation: Allocation) {
        assert(queue.isCurrent())
//        guard !allocation.isNode else { return}
//
//        if allocation.data.count > individualAllocationSize || availableCount >= 50 {
//            allocation.data.deallocate()
//        } else {
//            availableCount += 1
//            availableAllocations.append(allocation)
//        }
//        allocatedCount -= 1
        allocation.data.deallocate()
    }

    func trim() {
        assert(queue.isCurrent())
        fatalError()
    }
}

extension UnsafeMutableRawBufferPointer {
    static func allocateUInt8(byteCount: Int) -> Self {
        UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment)
    }
}
