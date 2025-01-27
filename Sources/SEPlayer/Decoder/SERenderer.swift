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
    let clock: CMClock
    let queue: Queue
    let sampleStream: SampleStream
    private let compressedSampleQueue: TypedCMBufferQueue<CMSampleBuffer>
    let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var startStream: Int64 = 1_000_000_000_000

    private var lastResetPosition: Int64 = .min
    private var lastSampleInStreamPTS: Int64 = .zero
    private var largestQueuedPTS: Int64 = .zero

    private var inputSample: CMSampleBuffer?

    private var outputSample: CMSampleBuffer?
    private var isDecodeOnlyOutputSample: Bool = false
    private var isLastOutputSample: Bool = false

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
            capacity: 10,
            handlers: .unsortedSampleBuffers
        )
    }

    func start() {
        
    }

    func isReady() -> Bool {
        return sampleStream.isReady() && outputSample != nil
    }

    func render(position: Int64, elapsedRealtime: Int64, completion: @escaping () -> Void) throws {
        while try drainOutputQueue(position: position, elapsedRealtime: elapsedRealtime) {}
        try drainInputQueueContiniously(position: position, elapsedRealtime: elapsedRealtime, completion: completion)
    }

    func drainOutputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        let sample = outputSample ?? decompressedSamplesQueue.dequeue()
        self.outputSample = sample

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
            return true
        }

        return false
    }

    private func drainInputQueueContiniously(position: Int64, elapsedRealtime: Int64, completion: @escaping () -> Void) throws {
        try drainInputQueue(position: position, elapsedRealtime: elapsedRealtime) { [weak self] success in
            guard let self else { return }
            do {
                if success {
                    resetInputBuffer()
                    try drainInputQueueContiniously(position: position, elapsedRealtime: elapsedRealtime, completion: completion)
                    return
                }
                completion()
            } catch {
                completion()
            }
        }
    }

    func drainInputQueue(position: Int64, elapsedRealtime: Int64, completion: @escaping (Bool) -> Void) throws {
        guard !decompressedSamplesQueue.isFull else {
            completion(false); return
        }
        let sample: CMSampleBuffer?
        if let inputSample {
            sample = inputSample
        } else {
            try sampleStream.readData(to: compressedSampleQueue)
            sample = compressedSampleQueue.dequeue()
        }

        guard let sample else { completion(false); return }
        largestQueuedPTS = max(largestQueuedPTS, sample.outputPresentationTimeStamp.microseconds)
        queueInputSample(sampleBuffer: sample) { result in
            completion(result)
        }
    }

    func queueInputSample(sampleBuffer: CMSampleBuffer, completion: @escaping (Bool) -> Void) {
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
}

private extension BaseSERenderer {
    func resetInputBuffer() {
        inputSample = nil
    }

    func resetOutputBuffer() {
        outputSample = nil
    }
}
