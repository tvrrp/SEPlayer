//
//  SampleDataQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 07.04.2025.
//

import string_h

final class SampleDataQueue {
    private let queue: Queue
    private let allocator: Allocator

    private let allocationLength: Int
    private var firstAllocationNode: SampleAllocationNode
    private var readAllocationNode: SampleAllocationNode
    private var writeAllocationNode: SampleAllocationNode

    private var totalBytesWritten: Int = 0

    init(queue: Queue, allocator: Allocator) {
        self.queue = queue
        self.allocator = allocator
        allocationLength = allocator.individualAllocationSize
        firstAllocationNode = SampleAllocationNode(
            allocation: allocator.allocate(),
            startPosition: 0,
            allocationLength: allocationLength
        )
        readAllocationNode = firstAllocationNode
        writeAllocationNode = firstAllocationNode
    }

    func reset() {
        assert(queue.isCurrent())
        clearAllocationNodes(fromNode: firstAllocationNode)
        firstAllocationNode = SampleAllocationNode(
            allocation: allocator.allocate(),
            startPosition: 0,
            allocationLength: allocationLength
        )
        readAllocationNode = firstAllocationNode
        writeAllocationNode = firstAllocationNode
        totalBytesWritten = 0
        allocator.trim()
    }

    func discardUpstreamSampleBytes(totalBytesWritten: Int) {
        assert(queue.isCurrent())
        guard totalBytesWritten <= self.totalBytesWritten else {
            assertionFailure()
            return
        }
        self.totalBytesWritten = totalBytesWritten
        if totalBytesWritten == 0 || totalBytesWritten == firstAllocationNode.startPosition {
            clearAllocationNodes(fromNode: firstAllocationNode)
            firstAllocationNode = SampleAllocationNode(
                allocation: allocator.allocate(),
                startPosition: totalBytesWritten,
                allocationLength: allocationLength
            )
            readAllocationNode = firstAllocationNode
            writeAllocationNode = firstAllocationNode
        } else {
            var lastNodeToKeep = firstAllocationNode
            while totalBytesWritten > lastNodeToKeep.endPosition, let next = lastNodeToKeep.nextNode {
                lastNodeToKeep = next
            }

            guard let firstNodeToDiscard = lastNodeToKeep.nextNode else {
                assertionFailure()
                return
            }

            clearAllocationNodes(fromNode: firstNodeToDiscard)
            let nextNode = SampleAllocationNode(
                allocation: allocator.allocate(),
                startPosition: lastNodeToKeep.endPosition,
                allocationLength: allocationLength
            )
            lastNodeToKeep.nextNode = nextNode
            writeAllocationNode = totalBytesWritten == lastNodeToKeep.endPosition ? nextNode : lastNodeToKeep
            if readAllocationNode === firstNodeToDiscard {
                readAllocationNode = nextNode
            }
        }
    }

    func rewind() {
        assert(queue.isCurrent())
        readAllocationNode = firstAllocationNode
    }

    func readToBuffer(buffer: UnsafeMutableRawPointer, offset: Int, size: Int) throws {
        assert(queue.isCurrent())
        readAllocationNode = try readData(
            allocationNode: readAllocationNode,
            absolutePosition: offset,
            target: buffer,
            size: size
        )
    }

    func peekToBuffer(buffer: UnsafeMutableRawPointer, offset: Int, size: Int) throws {
        assert(queue.isCurrent())
        try readData(
            allocationNode: readAllocationNode,
            absolutePosition: offset,
            target: buffer,
            size: size
        )
    }

    func discardDownstreamTo(absolutePosition: Int?) {
        assert(queue.isCurrent())
        guard let absolutePosition else { return }

        while absolutePosition >= firstAllocationNode.endPosition {
            allocator.release(allocation: firstAllocationNode.allocation)
            if let nextAllocation = firstAllocationNode.clear() {
                firstAllocationNode = nextAllocation
            }
        }
        if readAllocationNode.startPosition < firstAllocationNode.startPosition {
            readAllocationNode = firstAllocationNode
        }
    }

    func getTotalBytesWritten() -> Int {
        assert(queue.isCurrent())
        return totalBytesWritten
    }

    func loadSampleData(
        input: DataReader,
        length: Int,
        completionQueue: Queue,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        assert(queue.isCurrent())
        let readLenght = preAppend(length: length)

        input.read(
            allocation: writeAllocationNode.allocation,
            offset: writeAllocationNode.translateOffset(absolutePosition: totalBytesWritten),
            length: readLenght,
            completionQueue: queue
        ) { [weak self] result in
            guard let self else { return }
            assert(queue.isCurrent())

            switch result {
            case let .success(bytesRead):
                postAppend(length: bytesRead)
                completionQueue.async { completion(.success(bytesRead)) }
            case let .failure(error):
                completionQueue.async { completion(.failure(error)) }
            }
        }
    }

    private func clearAllocationNodes(fromNode: SampleAllocationNode) {
        assert(queue.isCurrent())
        allocator.release(allocationNode: fromNode)
        fromNode.clear()
    }

    private func preAppend(length: Int) -> Int {
        assert(queue.isCurrent())
        writeAllocationNode.initialize(
            next: SampleAllocationNode(
                allocation: allocator.allocate(),
                startPosition: writeAllocationNode.endPosition,
                allocationLength: allocationLength
            )
        )

        return min(length, writeAllocationNode.endPosition - totalBytesWritten)
    }

    private func postAppend(length: Int) {
        assert(queue.isCurrent())
        totalBytesWritten += length
        if totalBytesWritten == writeAllocationNode.endPosition,
           let next = writeAllocationNode.nextNode {
            writeAllocationNode = next
        }
    }

    @discardableResult
    private func readData(
        allocationNode: SampleAllocationNode,
        absolutePosition: Int,
        target: UnsafeMutableRawPointer,
        size: Int
    ) throws -> SampleAllocationNode {
        assert(queue.isCurrent())
        var node = getNodeContainingPosition(allocationNode: allocationNode, absolutePosition: absolutePosition)
        var remaining = size
        var absolutePosition = absolutePosition
        var bufferOffset = 0

        while remaining > 0 {
            let baseAdress = target.advanced(by: bufferOffset)
            let toCopy = min(remaining, node.endPosition - absolutePosition)
            let nodeOffset = node.translateOffset(absolutePosition: absolutePosition)
            memcpy(baseAdress, node.allocation.data.advanced(by: nodeOffset), toCopy)
            remaining -= toCopy
            absolutePosition += toCopy
            bufferOffset += toCopy

            if absolutePosition == node.endPosition, let next = node.nextNode {
                node = next
            }
        }

        return node
    }

    private func getNodeContainingPosition(
        allocationNode: SampleAllocationNode,
        absolutePosition: Int
    ) -> SampleAllocationNode {
        assert(queue.isCurrent())
        var node = allocationNode
        while absolutePosition >= node.endPosition, let next = node.nextNode {
            node = next
        }
        return node
    }
}

private final class SampleAllocationNode: AllocationNode {
    var startPosition: Int
    var endPosition: Int

    let allocation: Allocation
    var nextNode: SampleAllocationNode?

    init(allocation: Allocation, startPosition: Int, allocationLength: Int) {
        self.allocation = allocation
        self.startPosition = startPosition
        self.endPosition = startPosition + allocationLength
    }

    func reset(startPosition: Int, allocationLength: Int) {
        self.startPosition = startPosition
        endPosition = startPosition + allocationLength
    }

    func initialize(next: SampleAllocationNode) {
        self.nextNode = next
    }

    func translateOffset(absolutePosition: Int) -> Int {
        absolutePosition - startPosition
    }

    @discardableResult
    func clear() -> SampleAllocationNode? {
        let temp = nextNode
        nextNode = nil
        return temp
    }

    func getAllocation() -> Allocation {
        return allocation
    }

    func next() -> AllocationNode? {
        if nextNode == nil || nextNode?.allocation == nil {
            return nil
        }
        return nextNode
    }
}
