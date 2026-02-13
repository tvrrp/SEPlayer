//
//  SimpleDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.01.2026.
//

import CoreMedia

class SimpleDecoder<I: DecoderInputBuffer, O: SimpleDecoderOutputBuffer, E: Error>: Decoder {
    typealias InputBuffer = I
    typealias OutputBuffer = O
    typealias DecoderError = E

    var firstPresentationTimeStamp: CMTime? {
        let time = queuedOutputBuffers.firstPresentationTimeStamp
        return time.isValid ? time : nil
    }

    private let decodeQueue: Queue
    private let decodeActor: PlayerActor
    private let lock: UnfairLock

    private var queuedInputBuffers: [I]
    private var queuedOutputBuffers: TypedCMBufferQueue<O>

    private var availableInputBuffers: [I]
    private var availableOutputBuffers: [O]

    private var availableInputBufferCount: Int
    private var availableOutputBufferCount: Int

    private var dequeuedInputBuffer: I?

    private var decodeError: E?
    private var flushed = false
    private var released = false
    private var skippedOutputBufferCount = 0
    private var outputStartTimeUs = Int64.zero

    private var decodeContinuation: CheckedContinuation<Void, Never>?

    init(
        decodeQueue: Queue,
        inputBuffersCount: Int,
        outputBuffersCount: Int
    ) throws {
        self.decodeQueue = decodeQueue
        self.decodeActor = decodeQueue.playerActor()
        lock = UnfairLock()
        outputStartTimeUs = .timeUnset
        queuedInputBuffers = []
        queuedOutputBuffers = try .init(
            capacity: outputBuffersCount,
            compareHandler: { lhs, rhs in
                guard lhs.timeUs != rhs.timeUs else { return .compareEqualTo }
                return lhs.timeUs > rhs.timeUs ? .compareGreaterThan : .compareLessThan
            },
            ptsHandler: { .from(microseconds: $0.timeUs) }
        )

        availableInputBuffers = []
        availableInputBufferCount = inputBuffersCount
        availableOutputBuffers = []
        availableOutputBufferCount = outputBuffersCount

        availableInputBuffers = (0..<inputBuffersCount).map { _ in createInputBuffer() }
        availableOutputBuffers = (0..<outputBuffersCount).map { _ in createOutputBuffer() }

        Task {
            await run(isolated: decodeActor)
        }
    }

    final func setInitialInputBufferSize(_ size: Int) throws {
        try availableInputBuffers.forEach {
            try $0.ensureSpaceForWrite(size)
        }
    }

    final func isAtLeastOutputStartTimeUs(_ timeUs: Int64) -> Bool {
        lock.withLock {
            outputStartTimeUs == .timeUnset || timeUs >= outputStartTimeUs
        }
    }

    func setOutputStartTimeUs(_ outputStartTimeUs: Int64) {
        lock.withLock {
            self.outputStartTimeUs = outputStartTimeUs
        }
    }

    func dequeueInputBuffer() throws(E) -> I? {
        try lock.usingLock { () throws(E) -> I? in
            try maybeThrowError()
            if availableInputBufferCount == 0 {
                dequeuedInputBuffer = nil
            } else {
                availableInputBufferCount -= 1
                dequeuedInputBuffer = availableInputBuffers[availableInputBufferCount]
            }
            return dequeuedInputBuffer
        }
    }

    func queueInputBuffer(_ inputBuffer: I) throws(E) {
        try lock.usingLock { () throws(E) in
            try maybeThrowError()
            queuedInputBuffers.append(inputBuffer)
            maybeNotifyDecodeLoop()
            dequeuedInputBuffer = nil
        }
    }

    func dequeueOutputBuffer() throws(E) -> O? {
        try lock.usingLock { () throws(E) in
            try maybeThrowError()
            return queuedOutputBuffers.dequeue()
        }
    }

    func releaseOutputBuffer(_ outputBuffer: O) {
        lock.withLock {
            releaseOutputBufferInternal(outputBuffer)
            maybeNotifyDecodeLoop()
        }
    }

    func flush() {
        lock.withLock {
            flushed = true
            skippedOutputBufferCount = 0
            if let dequeuedInputBuffer {
                releaseInputBufferInternal(dequeuedInputBuffer)
                self.dequeuedInputBuffer = nil
            }

            queuedInputBuffers.forEach { releaseInputBufferInternal($0) }
            queuedInputBuffers.removeAll(keepingCapacity: true)
        }

        while let buffer = queuedOutputBuffers.dequeue() {
            buffer.release()
        }
    }

    func release() {
        lock.withLock {
            released = true
            decodeContinuation?.resume()
            decodeContinuation = nil
        }
    }

    private func maybeThrowError() throws(E) {
        if let decodeError {
            throw decodeError
        }
    }

    private func maybeNotifyDecodeLoop() {
        if canDecodeBuffer() {
            decodeContinuation?.resume()
            decodeContinuation = nil
        }
    }

    final func run(isolated: isolated PlayerActor) async {
        while await decode() {}
    }

    private func decode(isolated: isolated PlayerActor = #isolation) async -> Bool {
        var inputBuffer: I?
        var outputBuffer: O?
        var resetDecoder = false

        while lock.withLock({ !released && !canDecodeBuffer() }) {
            await withCheckedContinuation { continuation in
                lock.withLock { decodeContinuation = continuation }
            }
        }

        if lock.withLock({ released }) {
            return false
        }

        lock.withLock {
            inputBuffer = queuedInputBuffers.removeFirst()
            availableOutputBufferCount -= 1
            outputBuffer = availableOutputBuffers[availableOutputBufferCount]
            resetDecoder = flushed
            flushed = false
        }

        guard let inputBuffer, let outputBuffer else { return false }

        if inputBuffer.flags.contains(.endOfStream) {
            outputBuffer.sampleFlags.insert(.endOfStream)
        } else {
            outputBuffer.timeUs = inputBuffer.timeUs
            if inputBuffer.flags.contains(.firstSample) {
                outputBuffer.sampleFlags.insert(.firstSample)
            }
            if !isAtLeastOutputStartTimeUs(inputBuffer.timeUs) {
                outputBuffer.shouldBeSkipped = true
            }

            var decodeError: E?
            do {
                try await decode(inputBuffer: inputBuffer, outputBuffer: outputBuffer, reset: resetDecoder)
            } catch {
                decodeError = createDecodeError(error)
            }

            if let decodeError {
                lock.withLock { self.decodeError = decodeError }
                return false
            }
        }

        if resetDecoder {
            outputBuffer.release()
        } else if outputBuffer.shouldBeSkipped {
            lock.withLock { skippedOutputBufferCount += 1 }
            outputBuffer.release()
        } else {
            outputBuffer.skippedOutputBufferCount = skippedOutputBufferCount
            lock.withLock { skippedOutputBufferCount = 0 }

            do {
                try queuedOutputBuffers.enqueue(outputBuffer)
            } catch {
                lock.withLock { decodeError = createDecodeError(error) }
                return false
            }
        }

        lock.withLock { releaseInputBufferInternal(inputBuffer) }

        return true
    }

    private func canDecodeBuffer() -> Bool {
        !queuedInputBuffers.isEmpty && availableOutputBufferCount > 0
    }

    private func releaseInputBufferInternal(_ inputBuffer: I) {
        inputBuffer.clear()
        availableInputBuffers[availableInputBufferCount] = inputBuffer
        availableInputBufferCount += 1
    }

    private func releaseOutputBufferInternal(_ outputBuffer: O) {
        outputBuffer.clear()
        availableOutputBuffers[availableOutputBufferCount] = outputBuffer
        availableOutputBufferCount += 1
    }

    func setPlaybackSpeed(_ speed: Float) {}
    func createInputBuffer() -> I { fatalError() }
    func createOutputBuffer() -> O { fatalError() }
    func createDecodeError(_ error: Error) -> E { fatalError() }
    func decode(
        inputBuffer: I,
        outputBuffer: O,
        reset: Bool,
        isolation: isolated PlayerActor = #isolation
    ) async throws(E) { fatalError() }
}

public class SimpleDecoderOutputBuffer: TestDecoderOutputBuffer {
    public var sampleFlags: SampleFlags = []
    public var timeUs: Int64 = 0
    public var skippedOutputBufferCount: Int = 0
    public var shouldBeSkipped: Bool = false

    private let releaseCallback: ((SimpleDecoderOutputBuffer) -> Void)
    private let allocator = ByteBufferAllocator()
    private var data = ByteBuffer()

    public init(_ releaseCallback: @escaping (SimpleDecoderOutputBuffer) -> Void) {
        self.releaseCallback = releaseCallback
    }

    public func initBuffer(timeUs: Int64, size: Int) -> ByteBuffer {
        self.timeUs = timeUs
        if data.capacity < size {
            data = allocator.buffer(capacity: size)
        }

        data.clear()
        return data
    }

    public func release() {
        releaseCallback(self)
    }

    public func clear() {
        sampleFlags = []
        timeUs = 0
        skippedOutputBufferCount = 0
        shouldBeSkipped = false

        data.clear()
    }
}
