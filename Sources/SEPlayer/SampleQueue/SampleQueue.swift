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

        return .didReadBuffer(bufferFlags: wrapper.metadata.flags)
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
                    self.allocations.append(allocationWrapper)
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
        return !allocations.isEmpty
    }

    func skipCount(for time: CMTime, allowEndOfQueue: Bool) -> Int {
        return 0
    }

    func skip(count: Int) {
        readPosition += count
    }

    func discardTo(position: Int64, toKeyframe: Bool) {
        
    }
}

private extension SampleQueue {
    func createAllocation(with metadata: SampleMetadata) -> AllocationWrapper {
        assert(queue.isCurrent())

        return .init(metadata: metadata, allocation: allocator.allocate(capacity: metadata.size))
    }

    func releaseAllocation(from wrapper: AllocationWrapper) {
        assert(queue.isCurrent())
        allocator.release(allocation: wrapper.allocation)
    }
}

private extension SampleQueue {
    struct AllocationWrapper {
        let metadata: SampleMetadata
        let allocation: Allocation
    }
}
