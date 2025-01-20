//
//  SampleQueue.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

protocol SampleQueueDelegate: AnyObject {
    func sampleQueue(_ sampleQueue: SampleQueue, didProduceSample onTime: CMSampleTimingInfo)
}

final class SampleQueue: TrackOutput {
    let format: CMFormatDescription

    weak var delegate: SampleQueueDelegate? {
        didSet {
            assert(queue.isCurrent())
            allocations.forEach { delegate?.sampleQueue(self, didProduceSample: $0.metadata.sampleTimings) }
        }
    }

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
        guard allocations.count - 1 >= readPosition && !endOfQueue else { return .nothingRead }
//        let parentWrapper = allocations[readPosition]
        let parentWrapper = allocations.removeFirst()
        var nodeWrapper = parentWrapper.node
        var wrappers = [parentWrapper]

        while let wrapper = nodeWrapper {
            wrappers.append(wrapper)
            nodeWrapper = wrapper.node
            allocations.removeFirst()
        }

        let buffer = try CMBlockBuffer(
            length: wrappers.reduce(0) { $0 + $1.metadata.size },
            allocator: { size in
                return parentWrapper.allocation.baseAddress
            },
            deallocator: { _, _ in
                self.queue.async { self.releaseAllocation(from: parentWrapper) }
            },
            flags: .assureMemoryNow
        )

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: buffer,
            formatDescription: format,
            numSamples: wrappers.count,
            sampleTimings: wrappers.map { $0.metadata.sampleTimings },
            sampleSizes: wrappers.map { $0.metadata.size }
        )

        try decoderInput.enqueue(sampleBuffer)
        readPosition += wrappers.count
        endOfQueue = !wrappers.allSatisfy { !$0.metadata.flags.contains(.endOfStream) }
        return .didReadBuffer
    }

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
                    print("🙏 new metadata, type = \(self.format.mediaType), meta = \(metadata.sampleTimings.presentationTimeStamp.seconds)")
                    self.allocations.append(allocationWrapper)
                    self.delegate?.sampleQueue(self, didProduceSample: metadata.sampleTimings)
                    completionQueue.async { completion(nil) }
                case let .failure(error):
                    self.releaseAllocation(from: allocationWrapper)
                    completionQueue.async { completion(error) }
                }
            }
        }
    }

    func isReady(didFinish load: Bool) -> Bool {
        assert(queue.isCurrent())
        return true
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
        if let lastWrapper = allocations.last {
            let availableSize = lastWrapper.allocation.size - lastWrapper.metadata.size
            if availableSize >= metadata.size {
                let newWrapper = AllocationWrapper(
                    metadata: metadata, allocation: lastWrapper.allocation.createNode(from: lastWrapper.metadata.size)
                )
                newWrapper.parent = lastWrapper
                lastWrapper.node = newWrapper
                return newWrapper
            }
        }

        return .init(metadata: metadata, allocation: allocator.allocate(capacity: metadata.size))
    }

    func releaseAllocation(from wrapper: AllocationWrapper) {
        assert(queue.isCurrent())
        if let parent = wrapper.parent, wrapper.node == nil {
            wrapper.parent = nil
            parent.node = nil
            releaseAllocation(from: parent)
        } else if wrapper.node == nil {
            allocator.release(allocation: wrapper.allocation)
        }
    }
}

private extension SampleQueue {
    final class AllocationWrapper {
        let metadata: SampleMetadata
        let allocation: Allocation

        var node: AllocationWrapper?
        var parent: AllocationWrapper?
        var isReleased: Bool = false

        init(metadata: SampleMetadata, allocation: Allocation) {
            self.metadata = metadata
            self.allocation = allocation
        }
    }

//    struct AllocationWrapper {
//        let allocation: Allocation
//        
//        struct AllocationNode:
//    }
}
