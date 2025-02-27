//
//  SampleQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

final class SampleQueue: TrackOutput {
    let format: CMFormatDescription

    private let queue: Queue
    private let allocator: Allocator

    private var currentTime: CMTime = .zero
    private var allocations: [AllocationWrapper] = []

    private var endOfQueue = false
    private var readPosition: Int = 0
    private var length: Int = 0

    init(
        queue: Queue,
        allocator: Allocator,
        format: CMFormatDescription
    ) {
        self.queue = queue
        self.allocator = allocator
        self.format = format
    }

    func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
        assert(queue.isCurrent())
        guard !allocations.isEmpty && !endOfQueue else { return .nothingRead }
        let wrapper = allocations.removeFirst()

        let buffer = try CMBlockBuffer(
            length: wrapper.metadata.size,
            allocator: { size in
                return wrapper.allocation.baseAddress
            },
            deallocator: { _, _ in
                self.queue.async { self.releaseAllocation(from: wrapper) }
            },
            flags: .assureMemoryNow
        )

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: buffer,
            formatDescription: format,
            numSamples: 1,
            sampleTimings: [wrapper.metadata.sampleTimings],
            sampleSizes: [wrapper.metadata.size]
        )

        try decoderInput.enqueue(sampleBuffer)
        readPosition += 1
        endOfQueue = wrapper.metadata.flags.contains(.lastSample)

        return .didReadBuffer
    }

    func readData(to buffer: UnsafeMutableRawPointer) throws -> DecoderInputBuffer? {
        assert(queue.isCurrent())
        guard !allocations.isEmpty && !endOfQueue else { return nil }
        let wrapper = allocations.removeFirst()

        let pointer = malloc(wrapper.allocation.size).assumingMemoryBound(to: UInt8.self)
        buffer.copyMemory(
            from: wrapper.allocation.baseAddress,
            byteCount: wrapper.metadata.size
        )

        return .init(
            bufferFlags: wrapper.metadata.flags,
            format: format,
            data: buffer,
            sampleTimings: wrapper.metadata.sampleTimings
        )
    }

//    func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
//        assert(queue.isCurrent())
//        guard !blocks.isEmpty && !endOfQueue else { return .nothingRead }
//        let wrapper = blocks.removeFirst()
//
//        let sampleBuffer = try CMSampleBuffer(
//            dataBuffer: wrapper.block,
//            formatDescription: format,
//            numSamples: 1,
//            sampleTimings: [wrapper.metadata.sampleTimings],
//            sampleSizes: [wrapper.metadata.size]
//        )
//        try decoderInput.enqueue(sampleBuffer)
//        readPosition += 1
//        endOfQueue = wrapper.metadata.flags.contains(.endOfStream)
//
//        return .didReadBuffer
//    }

    func sampleData(input: DataReader, allowEndOfInput: Bool, metadata: SampleMetadata, completionQueue: Queue, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            let allocationWrapper = createAllocation(with: metadata)
            input.read(
                allocation: allocationWrapper.allocation,
                offset: allocationWrapper.allocation.offset,
                length: metadata.size,
                completionQueue: queue
            ) { result in
                assert(self.queue.isCurrent())
                switch result {
                case .success(_):
                    self.allocations.append(allocationWrapper)
                    completionQueue.async { completion(nil) }
                case let .failure(error):
                    self.releaseAllocation(from: allocationWrapper)
                    completionQueue.async { completion(error) }
                }
            }
        }
    }
    
//    func sampleData(input: any DataReader, allowEndOfInput: Bool, metadata: SampleMetadata, completionQueue: any Queue, completion: @escaping ((any Error)?) -> Void) {
//        queue.async { [weak self] in
//            guard let self else { return }
//            
//            var blockBuffer: CMBlockBuffer!
//            try! CMBlockBufferCreateWithMemoryBlock(
//                allocator: nil,
//                memoryBlock: nil,
//                blockLength: metadata.size,
//                blockAllocator: CMMemoryPoolGetAllocator(memoryPool),
//                customBlockSource: nil,
//                offsetToData: 0,
//                dataLength: metadata.size,
//                flags: 0,
//                blockBufferOut: &blockBuffer
//            ).validate()
//
//            input.read(blockBuffer: blockBuffer, offset: 0, length: metadata.size, completionQueue: queue) { result in
//                assert(self.queue.isCurrent())
//                switch result {
//                case .success(_):
//                    self.blocks.append(.init(metadata: metadata, block: blockBuffer))
//                    self.delegate?.sampleQueue(self, didProduceSample: metadata.sampleTimings)
//                    completionQueue.async { completion(nil) }
//                case let .failure(error):
//                    completionQueue.async { completion(error) }
//                }
//            }
//        }
//    }

    func isReady(didFinish load: Bool) -> Bool {
        assert(queue.isCurrent())
        return !allocations.isEmpty
    }

    func skipCount(for time: CMTime, allowEndOfQueue: Bool) -> Int {
        return 0
    }

    func skip(count: Int) {
        readPosition += count
    }
}

private extension SampleQueue {
    func createAllocation(with metadata: SampleMetadata) -> AllocationWrapper {
        assert(queue.isCurrent())
//        if let lastWrapper = allocations.last {
//            let availableSize = lastWrapper.allocation.size - lastWrapper.metadata.size
//            if availableSize >= metadata.size {
//                let newWrapper = AllocationWrapper(
//                    metadata: metadata, allocation: lastWrapper.allocation.createNode(from: lastWrapper.metadata.size)
//                )
//                newWrapper.parent = lastWrapper
//                lastWrapper.node = newWrapper
//                return newWrapper
//            }
//        }

        return .init(metadata: metadata, allocation: allocator.allocate(capacity: metadata.size))
    }

    func releaseAllocation(from wrapper: AllocationWrapper) {
        assert(queue.isCurrent())
//        if let parent = wrapper.parent, wrapper.node == nil {
//            wrapper.parent = nil
//            parent.node = nil
//            releaseAllocation(from: parent)
//        } else if wrapper.node == nil {
//            allocator.release(allocation: wrapper.allocation)
//        }
//        var currentNode = wrapper.node
//        wrapper.node = nil
//        while let node = currentNode {
//            node.parent = nil
//            currentNode = node.node
//        }
        allocator.release(allocation: wrapper.allocation)
    }
}

private extension SampleQueue {
    struct AllocationWrapper {
        let metadata: SampleMetadata
        let allocation: Allocation
    }
}
