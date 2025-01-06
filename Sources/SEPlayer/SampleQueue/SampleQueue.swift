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
    private var allocations: [CMTime: AllocationWrapper] = [:]

    private var readPosition: Int = 0
    private var length: Int = 0

    init(queue: Queue, allocator: Allocator, format: CMFormatDescription) {
        self.queue = queue
        self.allocator = allocator
        self.format = format
    }

    func readData(to decoderInput: TypedCMBufferQueue<CMSampleBuffer>) throws -> SampleStreamReadResult {
        assert(queue.isCurrent())
        guard let wrapper = allocations.removeValue(forKey: currentTime) else {
            return .nothingRead
        }

        let allocation = wrapper.allocation
        let buffer = try CMBlockBuffer(
            length: wrapper.metadata.size,
            allocator: { size in
                return allocation.data.baseAddress!.advanced(by: allocation.offset)
            },
            deallocator: { _, _ in
                self.allocator.release(allocation: allocation)
            },
            flags: .assureMemoryNow
        )

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: buffer,
            formatDescription: format,
            numSamples: 1,
            sampleTimings: [],
            sampleSizes: [wrapper.metadata.size]
        )

        try decoderInput.enqueue(sampleBuffer)
        return .didReadBuffer
    }

    func sampleData(input: DataReader, allowEndOfInput: Bool, metadata: SampleMetadata, completionQueue: Queue, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let allocation = allocator.allocate()
            input.read(allocation: allocation, offset: allocation.offset, length: metadata.size, completionQueue: queue) { result in
                switch result {
                case .success(_):
                    self.allocations[metadata.time] = .init(metadata: metadata, allocation: allocation)
                    completionQueue.async { completion(nil) }
                case let .failure(error):
                    self.allocator.release(allocation: allocation)
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
    var hasNextSample: Bool { false }
}

private extension SampleQueue {
    struct SampleExtrasHolder {
        var size: Int
        var offset: Int
    }

    struct AllocationWrapper {
        let metadata: SampleMetadata
        let allocation: Allocation
    }
}
