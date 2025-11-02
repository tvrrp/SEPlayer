//
//  CompressedBufferPool.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.10.2025.
//

final class CompressedBufferPool<CompressedBuffer, DecodedBuffer: AnyObject> {
    private let decodedQueue: TypedCMBufferQueue<DecodedBuffer>
    private let capacity: Int
    private let deallocateBuffer: ((CompressedBuffer) -> Void)

    private enum SlotState { case free, inUse }
    private var buffers: [CompressedBuffer]
    private var states: [SlotState]
    private var probe: Int = 0
    private var isReleased = false
    private var decodedCount: Int = 0
    private var reservedInFlight: Int = 0
    private var availableDecodedSlots: Int {
        capacity - decodedCount - reservedInFlight
    }

    init(
        capacity: Int,
        decodedQueue: TypedCMBufferQueue<DecodedBuffer>,
        allocateBuffer: (() -> CompressedBuffer),
        deallocateBuffer: @escaping (CompressedBuffer) -> Void
    ) {
        self.capacity = capacity
        self.decodedQueue = decodedQueue
        self.deallocateBuffer = deallocateBuffer
        buffers = (0..<capacity).map { _ in allocateBuffer() }
        states = Array(repeating: .free, count: capacity)
    }

    public func tryAcquireIndex() -> Int? {
        precondition(!isReleased, "Pool is released")
        guard availableDecodedSlots > 0, let idx = findFreeIndex() else { return nil }
        reservedInFlight += 1
        states[idx] = .inUse
        return idx
    }

    public func bufferView(for index: Int) -> CompressedBuffer {
        precondition(!isReleased, "Pool is released")
        guard states.indices.contains(index), states[index] == .inUse else {
            fatalError()
        }

        return buffers[index]
    }

    public func onDecodeSuccess(fromCompressedIndex index: Int, decoded: DecodedBuffer) throws {
        precondition(!isReleased, "Pool is released")
        releaseCompressedBuffer(index: index, consumedReserve: true)
        try decodedQueue.enqueue(decoded)
        decodedCount += 1
    }

    public func onDecodeError(fromCompressedIndex index: Int) {
        precondition(!isReleased, "Pool is released")
        releaseCompressedBuffer(index: index, consumedReserve: true)
    }

    public func dequeueDecoded() -> DecodedBuffer? {
        precondition(!isReleased, "Pool is released")
        if let v = decodedQueue.dequeue() {
            decodedCount = max(0, decodedCount - 1)
            return v
        }
        return nil
    }

    public func flush() throws {
        precondition(!isReleased, "Pool is released")
        while dequeueDecoded() != nil {}
    }

    public func release() throws {
        if isReleased { return }

        reservedInFlight = 0
        for i in states.indices { states[i] = .free }
        probe = 0
        try decodedQueue.reset()
        decodedCount = 0

        buffers.forEach { deallocateBuffer($0) }
        buffers.removeAll(keepingCapacity: false)
        states.removeAll(keepingCapacity: false)

        isReleased = true
    }

    private func findFreeIndex() -> Int? {
        let n = states.count
        for i in 0..<n {
            let idx = (probe + i) % n
            if states[idx] == .free {
                probe = (idx + 1) % n
                return idx
            }
        }
        return nil
    }

    private func releaseCompressedBuffer(index: Int, consumedReserve: Bool) {
        guard states.indices.contains(index), states[index] == .inUse else { return }
        states[index] = .free
        if consumedReserve { reservedInFlight = max(0, reservedInFlight - 1) }
    }
}
