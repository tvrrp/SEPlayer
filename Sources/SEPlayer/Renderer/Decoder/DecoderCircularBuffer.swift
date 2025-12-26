//
//  SimpleCircularBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.10.2025.
//

final class DecoderCircularBuffer<Buffer> {
    var isInputBufferAvailable: Bool { availableInputBuffers.first != nil }
    var isOutputBufferAvailable: Bool { availableOutputBuffers.first != nil }

    private let capacity: Int
    private let deallocateBuffer: ((Buffer) -> Void)

    private var compressedBuffers: [Buffer]
    private var decompressedBuffers: [Buffer]

    private var availableInputBuffers: CircularBuffer<Int>
    private var availableOutputBuffers: CircularBuffer<Int>

    private var isReleased = false

    init(
        capacity: Int,
        inputBufferSize: Int,
        outputBufferSize: Int,
        allocateBuffer: ((Int) -> Buffer),
        deallocateBuffer: @escaping (Buffer) -> Void
    ) {
        self.capacity = capacity
        self.deallocateBuffer = deallocateBuffer

        compressedBuffers = (0..<capacity).map { _ in allocateBuffer(inputBufferSize) }
        decompressedBuffers = (0..<capacity).map { _ in allocateBuffer(outputBufferSize) }

        availableInputBuffers = CircularBuffer<Int>(0..<capacity)
        availableOutputBuffers = CircularBuffer<Int>(0..<capacity)
    }

    func dequeueInputBufferIndex() -> Int? {
        precondition(!isReleased)
        return availableInputBuffers.popFirst()
    }

    func dequeueOutputBufferIndex() -> Int? {
        precondition(!isReleased)
        return availableOutputBuffers.popFirst()
    }

    func getInputBuffer(index: Int) -> Buffer {
        precondition(!isReleased)
        return compressedBuffers[index]
    }

    func getOutputBuffer(index: Int) -> Buffer {
        precondition(!isReleased)
        return decompressedBuffers[index]
    }

    func onInputBufferAvailable(index: Int) {
        precondition(!isReleased)
        availableInputBuffers.append(index)
    }

    func onOutputBufferAvailable(index: Int) {
        if isReleased {
            deallocateBuffer(decompressedBuffers[index])
        } else {
            availableOutputBuffers.append(index)
        }
    }

    func flush(releaseOutputBuffers: Bool = false) {
        precondition(!isReleased)
        availableInputBuffers = CircularBuffer<Int>(0..<capacity)

        if releaseOutputBuffers {
            availableOutputBuffers = CircularBuffer<Int>(0..<capacity)
        }
    }

    func release() {
        isReleased = true
        compressedBuffers.forEach { deallocateBuffer($0) }
        // we delay release of decompressedBuffers before CMSampleBuffer deinit
    }
}
