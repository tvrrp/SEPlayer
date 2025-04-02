//
//  SERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 14.01.2025.
//

import CoreMedia

protocol SERenderer {
    var trackType: TrackType { get }
    var state: SERendererState { get }
    var timebase: CMTimebase { get }
    var stream: SampleStream? { get }
    var streamDidEnd: Bool { get }
    var readingPosition: CMTime { get }
    var isReady: Bool { get }
    var isEnded: Bool { get }

    func onSleep()
    func onWakeup()

    func enable(
        formats: [CMFormatDescription],
        stream: SampleStream,
        position: CMTime,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func replaceStream(
        formats: [CMFormatDescription],
        stream: SampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws

    func start() throws
    func resetPosition(new time: CMTime) throws
    func setPlaybackSpeed(current: Float, target: Float) throws
    func setTimeline(_ timeline: Timeline)
    func render(position: CMTime) throws
    func stop()
    func disable()
    func reset()
    func release()
}

extension SERenderer {
    func durationToProgress(position: CMTime, elapsedRealtime: CMTime) -> CMTime {
        return .zero
    }
}

enum SERendererState {
    case disabled
    case enabled
    case started
}

class BaseSERenderer {
    var isStarted: Bool = false

    let clock: CMClock
    let queue: Queue
    let sampleStream: SampleStream
    private let compressedSampleQueue: TypedCMBufferQueue<CMSampleBuffer>
    let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>

    var playbackRate: Float = 1.0

    private let renderLimit: Int64 = 1000
    private var startStream: Int64 = 1_000_000_000_000

    private var lastResetPosition: Int64 = .min
    private var lastSampleInStreamPTS: Int64 = .zero
    private var largestQueuedPTS: Int64 = .zero

    private var inputSample: CMSampleBuffer?

    private var outputSample: CMSampleBuffer?
    private var isDecodeOnlyOutputSample: Bool = false
    private var isLastOutputSample: Bool = false
    private var _framedInQueue = 0

    init(
        clock: CMClock,
        queue: Queue,
        sampleStream: SampleStream
    ) throws {
        self.clock = clock
        self.queue = queue
        self.sampleStream = sampleStream
        self.compressedSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: 10,
            handlers: .unsortedSampleBuffers
        )
        self.decompressedSamplesQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: 100,
            handlers: .outputPTSSortedSampleBuffers
        )
    }

    func start() {
        isStarted = true
    }

    func isReady() -> Bool {
        return sampleStream.isReady() && !decompressedSamplesQueue.isEmpty //&& outputSample != nil
    }

    func getMediaClock() -> MediaClock? {
        return nil
    }

    func pause() {
        isStarted = false
    }

    func render(position: Int64, elapsedRealtime: Int64) throws {
        let startTime = clock.microseconds
        while try drainOutputQueue(position: position, elapsedRealtime: elapsedRealtime),
              shouldContinueRendering(from: startTime) {}
        while try drainInputQueue(position: position, elapsedRealtime: elapsedRealtime),
              shouldContinueRendering(from: startTime) {}
    }

    func drainOutputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        let sample = outputSample ?? decompressedSamplesQueue.dequeue()
//        self.outputSample = sample

        guard let sample else { return false }

        isDecodeOnlyOutputSample = sample.presentationTimeStamp.microseconds < lastResetPosition
        isLastOutputSample = lastSampleInStreamPTS != .zero && lastSampleInStreamPTS <= sample.presentationTimeStamp.microseconds

        if processOutputSample(position: position,
                               elapsedRealtime: elapsedRealtime,
                               outputStreamStartPosition: startStream,
                               presenationTime: startStream + sample.presentationTimeStamp.microseconds,
                               sample: sample,
                               isDecodeOnlySample: isDecodeOnlyOutputSample,
                               isLastOutputSample: isLastOutputSample) {
            resetOutputBuffer()
            _framedInQueue -= 1
            return true
        } else {
            resetOutputBuffer()
            try! decompressedSamplesQueue.enqueue(sample)
            return false
        }
    }

    func setPlaybackRate(new playbackRate: Float) throws {
        guard self.playbackRate != playbackRate else { return }
        self.playbackRate = playbackRate
    }

    func drainInputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        guard _framedInQueue < 10 else { return false }

        let sample: CMSampleBuffer?
        if let inputSample {
            sample = inputSample
        } else {
            try sampleStream.readData(to: compressedSampleQueue)
            sample = compressedSampleQueue.dequeue()
        }
        inputSample = sample

        guard let sample else {
            return false
        }
        largestQueuedPTS = max(largestQueuedPTS, sample.outputPresentationTimeStamp.microseconds)
        if queueInputSample(sampleBuffer: sample) {
            resetInputBuffer()
            _framedInQueue += 1
            return true
        } else {
            return false
        }
    }

    func queueInputSample(sampleBuffer: CMSampleBuffer) -> Bool {
        fatalError("to override")
    }

    func processOutputSample(
        position: Int64,
        elapsedRealtime: Int64,
        outputStreamStartPosition: Int64,
        presenationTime: Int64,
        sample: CMSampleBuffer,
        isDecodeOnlySample: Bool,
        isLastOutputSample: Bool
    ) -> Bool {
        fatalError("to override")
    }

    func shouldSkipInputSample(sample: CMSampleBuffer) -> Bool {
        return false
    }

    private func shouldContinueRendering(from startTime: Int64) -> Bool {
        return clock.microseconds - startTime < renderLimit
    }
}

private extension BaseSERenderer {
    func resetInputBuffer() {
        inputSample = nil
    }

    func resetOutputBuffer() {
        outputSample = nil
    }
}

class BaseSERenderer2 {
    private let queue: Queue
    private let trackType: TrackType
    private let clock: CMClock
    private let compressedSampleQueue: TypedCMBufferQueue<CMSampleBuffer>
    private let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var state: SERendererState = .disabled
    private var sampleStream: SampleStream?
    private var format: CMFormatDescription?

    private var streamIsFinal: Bool = false

    private var inputSample: CMSampleBuffer?
    private var outputSample: CMSampleBuffer?
    private var isDecodeOnlyOutputSample: Bool = false
    private var isLastOutputSample: Bool = false
    private var _framedInQueue = 0

    private var lastResetPosition: Int64 = .zero
    private var readindPosition: Int64 = .zero
    private var streamOffset: Int64 = .zero

    private var lastSampleInStreamPTS: Int64 = .zero
    private var largestQueuedPTS: Int64 = .zero

    init(queue: Queue, trackType: TrackType, clock: CMClock) throws {
        self.queue = queue
        self.trackType = trackType
        self.clock = clock
        compressedSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: 10,
            handlers: .unsortedSampleBuffers
        )
        decompressedSamplesQueue = try TypedCMBufferQueue<CMSampleBuffer>(
            capacity: 100,
            handlers: .outputPTSSortedSampleBuffers
        )
    }

    func onEnabled() {}
    func onStarted() {}
    func onStopped() {}
    func onDisabled() {}
    func onPositionReset(position: Int64, joining: Bool) throws {}
    func queueInputSample(sampleBuffer: CMSampleBuffer) -> Bool { return false }
    func processOutputSample(
        position: Int64,
        elapsedRealtime: Int64,
        outputStreamStartPosition: Int64,
        presentationTime: Int64,
        sample: CMSampleBuffer,
        isDecodeOnlySample: Bool,
        isLastOutputSample: Bool
    ) -> Bool {
        return false
    }

    func getMediaClock() -> MediaClock? { nil }
    func getClock() -> CMClock { clock }
    final func getState() -> SERendererState { state }
    final func getStream() -> SampleStream? { sampleStream }
    final func getFormat() -> CMFormatDescription? { format }
    final func getLastResetPosition() -> Int64 { lastResetPosition }
    final func getStreamOffset() -> Int64 { streamOffset }

    final func enable(
        format: CMFormatDescription,
        sampleStream: SampleStream,
        position: Int64,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: Int64,
        offset: Int64
    ) throws {
        assert(queue.isCurrent() && state == .disabled)
        state = .enabled
        self.sampleStream = sampleStream
        self.format = format
        onEnabled()
    }

    final func start() throws {
        assert(queue.isCurrent() && state == .enabled)
        state = .started
        onStarted()
    }

    final func stop() throws {
        assert(queue.isCurrent() && state == .started)
        state = .enabled
        onStopped()
    }

    final func disable() throws {
        assert(queue.isCurrent() && state == .enabled)
        state = .disabled
        sampleStream = nil
        format = nil
        streamIsFinal = false
        onDisabled()
    }

    final func resetPosition(new position: Int64) throws {
        try resetPosition(new: position, joining: false)
    }

    private func resetPosition(new position: Int64, joining: Bool) throws {
        streamIsFinal = false
        lastResetPosition = position
        readindPosition = position
        try onPositionReset(position: position, joining: joining)
    }

    final func render(position: Int64, elapsedRealtime: Int64) throws {
        let startTime = clock.microseconds
        while try drainOutputQueue(position: position, elapsedRealtime: elapsedRealtime),
              shouldContinueRendering(from: startTime) {}
        while try drainInputQueue(position: position, elapsedRealtime: elapsedRealtime),
              shouldContinueRendering(from: startTime) {}
    }

    private func drainOutputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        let sample = outputSample ?? decompressedSamplesQueue.dequeue()

        guard let sample else { return false }

        isDecodeOnlyOutputSample = sample.presentationTimeStamp.microseconds < lastResetPosition
        isLastOutputSample = lastSampleInStreamPTS != .zero && lastSampleInStreamPTS <= sample.presentationTimeStamp.microseconds

        if processOutputSample(position: position,
                               elapsedRealtime: elapsedRealtime,
                               outputStreamStartPosition: 0,
                               presentationTime: 0 + sample.presentationTimeStamp.microseconds,
                               sample: sample,
                               isDecodeOnlySample: isDecodeOnlyOutputSample,
                               isLastOutputSample: isLastOutputSample) {
            resetOutputBuffer()
            _framedInQueue -= 1
            return true
        } else {
            resetOutputBuffer()
            try! decompressedSamplesQueue.enqueue(sample)
            return false
        }
    }

    private func drainInputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        guard _framedInQueue < 10 else { return false }

        let sample: CMSampleBuffer?
        if let inputSample {
            sample = inputSample
        } else {
            try sampleStream?.readData(to: compressedSampleQueue)
            sample = compressedSampleQueue.dequeue()
        }
        inputSample = sample

        guard let sample else {
            return false
        }
        largestQueuedPTS = max(largestQueuedPTS, sample.outputPresentationTimeStamp.microseconds)
        if queueInputSample(sampleBuffer: sample) {
            resetInputBuffer()
            _framedInQueue += 1
            return true
        } else {
            return false
        }
    }

    private func readFromSource() throws {
        guard let sampleStream else { return }
        let result = try sampleStream.readData(to: compressedSampleQueue)
        
        switch result {
        case .didReadBuffer(_):
            print()
        case .nothingRead:
            print()
        }
    }
}

private extension BaseSERenderer2 {
    func resetInputBuffer() {
        inputSample = nil
    }

    func resetOutputBuffer() {
        outputSample = nil
    }

    private func shouldContinueRendering(from startTime: Int64) -> Bool {
        return clock.microseconds - startTime < .renderLimit
    }
}

private extension Int64 {
    static let renderLimit: Int64 = 1000
}
