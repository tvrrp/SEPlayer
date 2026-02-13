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
            startPosition: 0,
            allocationLength: allocationLength
        )
        readAllocationNode = firstAllocationNode
        writeAllocationNode = firstAllocationNode
    }

    func reset() {
        assert(queue.isCurrent())
        clearAllocationNodes(fromNode: firstAllocationNode)
        firstAllocationNode.reset(startPosition: 0, allocationLength: allocationLength)
        readAllocationNode = firstAllocationNode
        writeAllocationNode = firstAllocationNode
        totalBytesWritten = 0
        allocator.trim()
    }

    func discardUpstreamSampleBytes(totalBytesWritten: Int) {
        assert(queue.isCurrent())
        precondition(totalBytesWritten <= self.totalBytesWritten)
        self.totalBytesWritten = totalBytesWritten
        if totalBytesWritten == 0 || totalBytesWritten == firstAllocationNode.startPosition {
            clearAllocationNodes(fromNode: firstAllocationNode)
            firstAllocationNode = SampleAllocationNode(
                startPosition: self.totalBytesWritten,
                allocationLength: allocationLength
            )
            readAllocationNode = firstAllocationNode
            writeAllocationNode = firstAllocationNode
        } else {
            var lastNodeToKeep = firstAllocationNode
            while totalBytesWritten > lastNodeToKeep.endPosition {
                if let next = lastNodeToKeep.nextNode {
                    lastNodeToKeep = next
                } else {
                    assertionFailure()
                }
            }

            guard let firstNodeToDiscard = lastNodeToKeep.nextNode else {
                assertionFailure()
                return
            }

            clearAllocationNodes(fromNode: firstNodeToDiscard)
            let nextNode = SampleAllocationNode(
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

    func readToBuffer(target: UnsafeMutableRawBufferPointer, offset: Int, size: Int) throws {
        assert(queue.isCurrent())
        readAllocationNode = try readData(
            allocationNode: readAllocationNode,
            absolutePosition: offset,
            target: target,
            size: size
        )
    }

    func peekToBuffer(target: UnsafeMutableRawBufferPointer, offset: Int, size: Int) throws {
        assert(queue.isCurrent())
        try! readData(
            allocationNode: readAllocationNode,
            absolutePosition: offset,
            target: target,
            size: size
        )
    }

    func discardDownstreamTo(absolutePosition: Int?) {
        assert(queue.isCurrent())
        guard let absolutePosition else { return }

        while absolutePosition >= firstAllocationNode.endPosition {
            // Advance firstAllocationNode to the specified absolute position. Also clear nodes that are
            // advanced past, and return their underlying allocations to the allocator.
            if let allocation = firstAllocationNode.getAllocation() {
                allocator.release(allocation: allocation)
            } else {
                assertionFailure()
            }

            if let nextAllocation = firstAllocationNode.clear() {
                firstAllocationNode = nextAllocation
            } else {
                assertionFailure()
            }
        }

        if readAllocationNode.startPosition < firstAllocationNode.startPosition {
            readAllocationNode = firstAllocationNode
        }
    }

    func getTotalBytesWritten() -> Int { totalBytesWritten }

    func loadSampleData(
        input: DataReader,
        length: Int,
        allowEndOfInput: Bool,
        isolation: isolated any Actor
    ) async throws -> DataReaderReadResult {
        let readLenght = preAppend(length: length)
        let result = try await input.read(
            allocation: writeAllocationNode.allocation!,
            offset: writeAllocationNode.translateOffset(absolutePosition: totalBytesWritten),
            length: readLenght,
            isolation: isolation
        )

        switch result {
        case let .success(bytesAppended):
            postAppend(length: bytesAppended)
            return result
        case .endOfInput:
            if allowEndOfInput {
                return .endOfInput
            }
            throw ErrorBuilder(errorDescription: "end of file")
            // TODO: throw error
//            fatalError()
        }
    }

    func loadSampleData(buffer: ByteBuffer, length: Int, isolation: isolated any Actor) throws {
        var length = length
        var buffer = buffer

        while length > 0 {
            let bytesAppended = preAppend(length: length)
            let bytes = try buffer.readData(count: bytesAppended)
            writeAllocationNode.allocation!.writeBytes(
                offset: writeAllocationNode.translateOffset(absolutePosition: totalBytesWritten),
                lenght: bytesAppended,
                buffer: bytes
            )
            length -= bytesAppended
            postAppend(length: bytesAppended)
        }
    }

    private func clearAllocationNodes(fromNode: SampleAllocationNode) {
        assert(queue.isCurrent())
        guard fromNode.allocation != nil else { return }
        allocator.release(allocationNode: fromNode)
        fromNode.clear()
    }

    private func preAppend(length: Int) -> Int {
        if writeAllocationNode.allocation == nil {
            writeAllocationNode.initialize(
                allocation: allocator.allocate(),
                next: SampleAllocationNode(
                    startPosition: writeAllocationNode.endPosition,
                    allocationLength: allocationLength
                )
            )
        }

        return min(length, writeAllocationNode.endPosition - totalBytesWritten)
    }

    private func postAppend(length: Int) {
        totalBytesWritten += length
        if totalBytesWritten == writeAllocationNode.endPosition {
            if let next = writeAllocationNode.nextNode {
                writeAllocationNode = next
            } else {
                assertionFailure()
            }
        }
    }

    @discardableResult
    private func readData(
        allocationNode: SampleAllocationNode,
        absolutePosition: Int,
        target: UnsafeMutableRawBufferPointer,
        size: Int
    ) throws -> SampleAllocationNode {
        assert(queue.isCurrent())
        var node = getNodeContainingPosition(allocationNode: allocationNode, absolutePosition: absolutePosition)
        var remaining = size
        var absolutePosition = absolutePosition
        var bufferOffset = 0

        while remaining > 0 {
            let toCopy = min(remaining, node.endPosition - absolutePosition)
            let nodeOffset = node.translateOffset(absolutePosition: absolutePosition)
            let nodeBuffer = node.allocation!.data
            let nodeRange = nodeOffset..<(nodeOffset + toCopy)

            let pasteBuffer = UnsafeMutableRawBufferPointer(rebasing: target[bufferOffset..<target.count])
            let copyBuffer = UnsafeMutableRawBufferPointer(rebasing: nodeBuffer[nodeRange])
            pasteBuffer.copyBytes(from: copyBuffer)

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
        while absolutePosition >= node.endPosition {
            if let next = node.nextNode {
                node = next
            } else {
                assertionFailure()
            }
        }

        return node
    }
}

private final class SampleAllocationNode: AllocationNode {
    private(set) var startPosition: Int
    private(set) var endPosition: Int

    var allocation: Allocation?
    var nextNode: SampleAllocationNode?

    init(startPosition: Int, allocationLength: Int) {
        self.startPosition = startPosition
        self.endPosition = startPosition + allocationLength
    }

    func reset(startPosition: Int, allocationLength: Int) {
        precondition(allocation == nil)
        self.startPosition = startPosition
        endPosition = startPosition + allocationLength
    }

    func initialize(allocation: Allocation, next: SampleAllocationNode) {
        self.allocation = allocation
        self.nextNode = next
    }

    func translateOffset(absolutePosition: Int) -> Int {
        absolutePosition - startPosition
    }

    @discardableResult
    func clear() -> SampleAllocationNode? {
        allocation = nil
        let temp = nextNode
        nextNode = nil
        return temp
    }

    func getAllocation() -> Allocation? {
        precondition(allocation != nil)
        return allocation
    }

    func next() -> AllocationNode? {
        if let nextNode, nextNode.allocation != nil {
            return nextNode
        } else {
            return nil
        }
    }
}
