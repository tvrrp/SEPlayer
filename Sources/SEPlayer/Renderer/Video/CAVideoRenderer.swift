//
//  CARenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.04.2025.
//

import CoreMedia

protocol CARendererDecoder: SEDecoder where OutputBuffer: CoreVideoBuffer {
    static func getCapabilities() -> RendererCapabilities
    func setPlaybackSpeed(_ speed: Float)
    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool
}

protocol CoreVideoBuffer: DecoderOutputBuffer {
    var imageBuffer: CVImageBuffer? { get }
}

final class CAVideoRenderer<Decoder: CARendererDecoder>: BaseSERenderer {
    private var decoder: Decoder?
    private let queue: Queue
    private let bufferableContainer: PlayerBufferableContainer
    private let decoderFactory: SEDecoderFactory

    private let flagsOnlyBuffer: DecoderInputBuffer
    private var inputFormat: CMFormatDescription?

    private var inputIndex: Int?
    private var inputBuffer: DecoderInputBuffer
    private var outputBuffer: CoreVideoBuffer?

    private var decoderReinitializationState: DecoderReinitializationState = .none
    private var decoderReceivedBuffers: Bool = false

    private var initialPosition: Int64?
    private var waitingForFirstSampleInFormat = false

    private var inputStreamEnded = false
    private var outputStreamEnded = false

    private var buffersInCodecCount = 0
    private var lastRenderTime: Int64 = 0

    private var videoFrameReleaseControl: VideoFrameReleaseControl
    private let outputSampleQueue: TypedCMBufferQueue<ImageBufferWrapper>

    private var playbackSpeed: Float = 1.0
    private var startPosition: Int64?
    private var lastFrameReleaseTime: Int64 = .zero

    private var pendingFramesAfterStop: [ImageBufferWrapper] = []

    init(
        queue: Queue,
        clock: CMClock,
        displayLink: DisplayLinkProvider,
        bufferableContainer: PlayerBufferableContainer,
        decoderFactory: SEDecoderFactory
    ) throws {
        self.queue = queue
        self.bufferableContainer = bufferableContainer
        self.videoFrameReleaseControl = VideoFrameReleaseControl(
            queue: queue,
            clock: clock,
            displayLink: displayLink,
            allowedJoiningTimeMs: .zero
        )
        self.decoderFactory = decoderFactory

        outputSampleQueue = try! TypedCMBufferQueue(compareHandler: { rhs, lhs in
            guard rhs.presentationTime != lhs.presentationTime else { return .compareEqualTo }
            return rhs.presentationTime > lhs.presentationTime ? .compareGreaterThan : .compareLessThan
        }, ptsHandler: { buffer in
            return CMTime.from(nanoseconds: buffer.presentationTime)
        })
        flagsOnlyBuffer = DecoderInputBuffer()
        inputBuffer = DecoderInputBuffer()

        super.init(queue: queue, trackType: .video, clock: clock)
        videoFrameReleaseControl.frameTimingEvaluator = self
    }

    override func getCapabilities() -> RendererCapabilities {
        Decoder.getCapabilities()
    }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        guard !outputStreamEnded else { return }

        if inputFormat == nil {
            let result = try! readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)
            switch result {
            case let .didReadFormat(format):
                try! onInputFormatChanged(format: format)
            case .didReadBuffer:
                guard flagsOnlyBuffer.flags.contains(.endOfStream) else {
                    fatalError() // TODO: throw error
                }
                inputStreamEnded = true
                outputStreamEnded = true
                return
            case .nothingRead:
                return
            }
        }

        try! maybeInitDecoder()

        if decoder != nil {
            while try! drainOutputBuffer(position: position, elapsedRealtime: elapsedRealtime) {}
            while try! feedInputBuffer() {}
        }
    }

    override func isEnded() -> Bool { outputStreamEnded }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        try! super.onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        videoFrameReleaseControl.enable(releaseFirstFrameBeforeStarted: mayRenderStartOfStream)
        bufferableContainer.prepare(sampleQueue: outputSampleQueue, action: .reset)
    }

    override func enableRenderStartOfStream() {
        videoFrameReleaseControl.allowReleaseFirstFrameBeforeStarted()
    }

    override func onStreamChanged(
        formats: [CMFormatDescription],
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {
        try! super.onStreamChanged(
            formats: formats,
            startPosition: startPosition,
            offset: offset,
            mediaPeriodId: mediaPeriodId
        )
        if self.startPosition == nil {
            self.startPosition = startPosition
        }

        onProcessedStreamChange()
    }

    private func onProcessedStreamChange() {
        videoFrameReleaseControl.processedStreamChanged()
    }

    private func updatePeriodDuration() {
        // TODO:
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        try! super.onPositionReset(position: position, joining: joining)
        print("ON POSITION RESEEEEEEET, new position = \(position)")
        print()
        print()
        print()
        print()
        print()
        print()
        print()
        inputStreamEnded = false
        outputStreamEnded = false
        initialPosition = nil
        if decoder != nil {
            try! flushDecoder()
        }

        videoFrameReleaseControl.reset()
        if joining {
            videoFrameReleaseControl.join(renderNextFrameImmediately: false)
        }
    }

    override func isReady() -> Bool {
        let rendererOtherwiseReady = inputFormat != nil && (isSourceReady() || outputBuffer != nil)
        if rendererOtherwiseReady, decoder == nil {
            return true
        }
        return videoFrameReleaseControl.isReady(rendererOtherwiseReady: rendererOtherwiseReady)
    }

    override func onStarted() throws {
        try! super.onStarted()
        lastRenderTime = getClock().microseconds
        bufferableContainer.start()
        videoFrameReleaseControl.start()
    }

    override func onStopped() {
        bufferableContainer.stop()
        videoFrameReleaseControl.stop()
        while let sampleWrapper = outputSampleQueue.dequeue() {
            pendingFramesAfterStop.append(sampleWrapper)
        }
        super.onStopped()
    }

    override func onDisabled() {
        inputFormat = nil
        try! outputSampleQueue.reset()
        releaseDecoder()
        videoFrameReleaseControl.stop()
        bufferableContainer.end()
        super.onDisabled()
    }

    override func onReset() {
        super.onReset()
        startPosition = nil
    }

    private func flushDecoder() throws {
        buffersInCodecCount = 0
        try! outputSampleQueue.reset()
        bufferableContainer.flush()
        if decoderReinitializationState != .none {
            releaseDecoder()
            try! maybeInitDecoder()
        } else {
            resetInputBuffer()
            outputBuffer = nil
            try! decoder?.flush()
            decoderReceivedBuffers = false
        }
    }

    private func releaseDecoder() {
        resetInputBuffer()
        outputBuffer = nil
        decoderReinitializationState = .none
        decoderReceivedBuffers = false
        buffersInCodecCount = 0
        pendingFramesAfterStop.removeAll()
        try? outputSampleQueue.reset()
        bufferableContainer.flush()
        bufferableContainer.prepare(sampleQueue: outputSampleQueue, action: .reset)

        if let decoder {
            decoder.release()
            self.decoder = nil
        }
    }

    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool {
        decoder?.canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) ?? false
    }

    func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }
        let decoder = try! createDecoder(format: inputFormat)
        self.decoder = decoder
    }

    func createDecoder(format: CMFormatDescription) throws -> Decoder {
        let decoder = try! decoderFactory.create(type: Decoder.self, queue: queue, format: format)
        decoder.setPlaybackSpeed(playbackSpeed)
        return decoder
    }

    func onInputFormatChanged(format: CMFormatDescription) throws {
        waitingForFirstSampleInFormat = true
        let oldFormat = inputFormat
        inputFormat = format

        if decoder == nil {
            try! maybeInitDecoder()
            return
        }

        let reuseResult = canReuseDecoder(oldFormat: oldFormat, newFormat: format)
        if !reuseResult {
            if decoderReceivedBuffers {
                decoderReinitializationState = .signalEndOfStream
            } else {
                releaseDecoder()
                try! maybeInitDecoder()
            }
        }
    }

    override func setPlaybackSpeed(current: Float, target: Float) throws {
        try! super.setPlaybackSpeed(current: current, target: target)
        self.playbackSpeed = current
        videoFrameReleaseControl.setPlaybackSpeed(current)
        decoder?.setPlaybackSpeed(current)
    }

    func feedInputBuffer() throws -> Bool {
        guard let decoder, decoderReinitializationState != .waitEndOfStream, !inputStreamEnded else {
            return false
        }

        if inputIndex == nil {
            inputIndex = decoder.dequeueInputBufferIndex()
            guard let inputIndex else { return false }

            inputBuffer.enqueue(buffer: decoder.dequeueInputBuffer(for: inputIndex))
        }

        guard let inputIndex else { return false }

        if decoderReinitializationState == .signalEndOfStream {
            inputBuffer.flags.insert(.endOfStream)
            try! decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
            resetInputBuffer()
            decoderReinitializationState = .waitEndOfStream
            return false
        }

        switch try! readSource(to: inputBuffer) {
        case let .didReadFormat(format):
            try! onInputFormatChanged(format: format)
            return true
        case .didReadBuffer:
            if inputBuffer.flags.contains(.endOfStream) {
                inputStreamEnded = true
                try! decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
                resetInputBuffer()
                return false
            }
//            if waitingForFirstSampleInFormat, let inputFormat {
//                formatQueue.add(timestamp: inputBuffer.time, value: inputFormat)
//                waitingForFirstSampleInFormat = false
//            }
            try! decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
            buffersInCodecCount += 1
            decoderReceivedBuffers = true
            resetInputBuffer()
            return true
        case .nothingRead:
            return false
        }
    }

    private func drainOutputBuffer(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        outputBuffer = if let outputBuffer = self.outputBuffer {
            outputBuffer
        } else if !pendingFramesAfterStop.isEmpty {
            pendingFramesAfterStop.removeFirst().buffer
        } else {
            decoder?.dequeueOutputBuffer()
        }

        guard let outputBuffer else { return false }

        if outputBuffer.sampleFlags.contains(.endOfStream) {
            if decoderReinitializationState == .waitEndOfStream {
                releaseDecoder()
                try! maybeInitDecoder()
            } else {
                self.outputBuffer = nil
                outputStreamEnded = true
            }

            return false
        }

        if processOutputBuffer(buffer: outputBuffer, position: position, elapsedRealtime: elapsedRealtime) {
            self.outputBuffer = nil
            return true
        }

        return false
    }

    func processOutputBuffer(buffer: CoreVideoBuffer, position: Int64, elapsedRealtime: Int64) -> Bool {
        let buffer = pendingFramesAfterStop.isEmpty ? buffer : pendingFramesAfterStop.removeFirst().buffer

        let outputStreamOffset = getStreamOffset()

        let isDecodeOnlyFrame = buffer.presentationTime < getLastResetPosition()
//        let isLastOutputBuffer = lastB // TODO: is last

        let frameReleaseAction = videoFrameReleaseControl.frameReleaseAction(
            presentationTimeUs: buffer.presentationTime,
            positionUs: position,
            elapsedRealtimeUs: elapsedRealtime,
            outputStreamStartPositionUs: outputStreamOffset,
            isDecodeOnlyFrame: isDecodeOnlyFrame,
            isLastFrame: false
        )

        print("💔 action = \(frameReleaseAction), time = \(buffer.presentationTime)")
        let result: Bool
        switch frameReleaseAction {
        case .immediately:
            if let imageBuffer = buffer.imageBuffer {
                bufferableContainer.renderImmediately(imageBuffer)
            }
            videoFrameReleaseControl.didReleaseFrame()
            result = true
        case let .scheduled(releaseTime):
            do {
                if releaseTime != lastFrameReleaseTime {
                    try! outputSampleQueue.enqueue(.init(buffer: buffer, presentationTime: releaseTime))
                    videoFrameReleaseControl.didReleaseFrame()
                }
                lastFrameReleaseTime = releaseTime
                result = true
            } catch {
                result = false
            }
        case .tryAgainLater:
            result = false
        case .ignore, .skip, .drop:
            result = true
        }

        return result
    }
}

extension CAVideoRenderer: VideoFrameReleaseControl.FrameTimingEvaluator {
    func shouldForceReleaseFrame(earlyTimeUs: Int64, elapsedSinceLastReleaseUs: Int64) -> Bool {
        return earlyTimeUs < -30_000 && elapsedSinceLastReleaseUs > 100_000
    }

    func shouldDropFrame(earlyTimeUs: Int64, elapsedSinceLastReleaseUs: Int64, isLast: Bool) -> Bool {
        return earlyTimeUs < -30_000 && !isLast
    }

    func shouldIgnoreFrame(earlyTimeUs: Int64, positionUs: Int64, elapsedRealtimeUs: Int64, isLast: Bool, treatDroppedAsSkipped: Bool) -> Bool {
        return (earlyTimeUs < -500_000 && !isLast)
    }
}

private extension CAVideoRenderer {
    func resetInputBuffer() {
        inputIndex = nil
        inputBuffer.reset()
    }
}

final class ImageBufferWrapper: CoreVideoBuffer {
    var imageBuffer: CVImageBuffer? { buffer.imageBuffer }
    var sampleFlags: SampleFlags  { buffer.sampleFlags }
    let presentationTime: Int64

    fileprivate let buffer: CoreVideoBuffer

    init(buffer: CoreVideoBuffer, presentationTime: Int64) {
        self.buffer = buffer
        self.presentationTime = presentationTime
    }
}
