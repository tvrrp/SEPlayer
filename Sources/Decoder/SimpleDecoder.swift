//
//  SimpleDecoder.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 18.01.2026.
//

import CoreMedia
import SEPlayerCommon

open class SimpleDecoder<I: DecoderInputBuffer, O: SimpleDecoderOutputBuffer, E: Error>: Decoder {
    public typealias InputBuffer = I
    public typealias OutputBuffer = O
    public typealias DecoderError = E

    public var firstPresentationTimeStamp: CMTime? {
        let time = queuedOutputBuffers.firstPresentationTimeStamp
        return time.isValid ? time : nil
    }

    public var onInputBufferAvailable: (() -> Void)? {
        get { lock.withLock { _onInputBufferAvailable } }
        set { lock.withLock { _onInputBufferAvailable = newValue } }
    }
    var _onInputBufferAvailable: (() -> Void)?

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
    private var outputStartTime: CMTime

    private var decodeContinuation: CheckedContinuation<Void, Never>?

    public init(
        decodeQueue: Queue,
        inputBuffersCount: Int,
        outputBuffersCount: Int,
        handlers: CMBufferQueue.Handlers? = nil
    ) throws {
        self.decodeQueue = decodeQueue
        self.decodeActor = decodeQueue.playerActor()
        lock = UnfairLock()
        outputStartTime = .invalid
        queuedInputBuffers = []
        if let handlers {
            queuedOutputBuffers = try .init(capacity: outputBuffersCount, handlers: handlers)
        } else {
            queuedOutputBuffers = try .init(
                capacity: outputBuffersCount,
                compareHandler: { lhs, rhs in
                    if lhs.sampleFlags.contains(.endOfStream) {
                        return .compareGreaterThan
                    }
                    if rhs.sampleFlags.contains(.endOfStream) {
                        return .compareLessThan
                    }
                    if lhs.time.presentationTimeStamp == rhs.time.presentationTimeStamp {
                        return .compareEqualTo
                    }

                    return lhs.time.presentationTimeStamp > rhs.time.presentationTimeStamp ? .compareGreaterThan : .compareLessThan
                },
                ptsHandler: { $0.time.presentationTimeStamp },
                durationHandler: { $0.time.duration }
            )
        }

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

    public func installTrigger(condition: CMBufferQueue.TriggerCondition, _ body: CMBufferQueueTriggerHandler?) throws -> CMBufferQueue.TriggerToken {
        try! queuedOutputBuffers.installTrigger(condition: condition, body)
    }

    public func removeTrigger(_ triggerToken: CMBufferQueue.TriggerToken) throws {
        try queuedOutputBuffers.removeTrigger(triggerToken)
    }

    public func testTrigger(_ triggerToken: CMBufferQueue.TriggerToken) -> Bool {
        queuedOutputBuffers.testTrigger(triggerToken)
    }

    public final func setInitialInputBufferSize(_ size: Int) throws {
        try availableInputBuffers.forEach {
            try $0.ensureSpaceForWrite(size)
        }
    }

    public final func isAtLeastOutputStartTime(_ time: CMTime) -> Bool {
        lock.withLock {
            !outputStartTime.isValid || time >= outputStartTime
        }
    }

    open func setOutputStartTime(_ outputStartTime: CMTime) {
        lock.withLock {
            self.outputStartTime = outputStartTime
        }
    }

    open func dequeueInputBuffer() throws(E) -> I? {
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

    open func queueInputBuffer(_ inputBuffer: I) throws(E) {
        try lock.usingLock { () throws(E) in
            try maybeThrowError()
            queuedInputBuffers.append(inputBuffer)
            maybeNotifyDecodeLoop()
            dequeuedInputBuffer = nil
        }
    }

    open func dequeueOutputBuffer() throws(E) -> O? {
        try lock.usingLock { () throws(E) in
            try maybeThrowError()
            return queuedOutputBuffers.dequeue()
        }
    }

    open func releaseOutputBuffer(_ outputBuffer: O) {
        lock.withLock {
            releaseOutputBufferInternal(outputBuffer)
            maybeNotifyDecodeLoop()
        }
    }

    open func flush() {
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

    open func release() {
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
            outputBuffer.time = inputBuffer.time
            if inputBuffer.flags.contains(.firstSample) {
                outputBuffer.sampleFlags.insert(.firstSample)
            }
            if !isAtLeastOutputStartTime(inputBuffer.time.presentationTimeStamp) {
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
        onInputBufferAvailable?()

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

    open func setPlaybackSpeed(_ speed: Float) {}
    open func createInputBuffer() -> I { fatalError() }
    open func createOutputBuffer() -> O { fatalError() }
    open func createDecodeError(_ error: Error) -> E { fatalError() }
    open func decode(
        inputBuffer: I,
        outputBuffer: O,
        reset: Bool,
        isolation: isolated PlayerActor = #isolation
    ) async throws(E) { fatalError() }
}
