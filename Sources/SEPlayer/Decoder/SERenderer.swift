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

//        return false
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
