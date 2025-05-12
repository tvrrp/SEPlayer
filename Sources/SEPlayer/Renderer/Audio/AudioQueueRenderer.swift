//
//  AudioQueueRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.04.2025.
//

import AudioToolbox
import CoreMedia

protocol AQDecoder: SEDecoder where OutputBuffer: AQOutputBuffer {
    static func getCapabilities() -> RendererCapabilities
    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool
}

protocol AQOutputBuffer: DecoderOutputBuffer {
    var audioBuffer: CMSampleBuffer? { get }
}

final class AudioQueueRenderer<Decoder: AQDecoder>: BaseSERenderer {
    private var decoder: Decoder?
    private let audioSink: IAudioSink
    private let queue: Queue
    private let decoderFactory: SEDecoderFactory

    private let flagsOnlyBuffer: DecoderInputBuffer
    private var inputFormat: CMFormatDescription?

    private var inputIndex: Int?
    private var inputBuffer: DecoderInputBuffer
    private var outputBuffer: AQOutputBuffer?

    private var decoderReinitializationState: DecoderReinitializationState = .none
    private var decoderReceivedBuffers = false
    private var audioTrackNeedsConfigure = false

    private var initialPosition: Int64?
    private var waitingForFirstSampleInFormat = false

    private var allowPositionDiscontinuity = false
    private var inputStreamEnded = false
    private var outputStreamEnded = false

    private var outputStreamOffset: Int64?

    private var buffersInCodecCount = 0
    private var lastRenderTime: Int64 = 0

    private let outputSampleQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var playbackSpeed: Float = 1.0
    private var startPosition: Int64?
    private var lastFrameReleaseTime: Int64 = .zero

    private var largestQueuedPresentationTime: Int64?
    private var lastBufferInStreamPresentationTime: Int64?
    private var nextBufferToWritePresentationTime: Int64?

    private var firstStreamSampleRead = false

    private var currentPosition: Int64 = .zero

    init(queue: Queue, clock: CMClock, audioSink: IAudioSink? = nil, decoderFactory: SEDecoderFactory) throws {
        self.queue = queue
        self.audioSink = audioSink ?? AudioSink(queue: queue, clock: clock)
        self.decoderFactory = decoderFactory
        outputSampleQueue = try TypedCMBufferQueue<CMSampleBuffer>()
        flagsOnlyBuffer = DecoderInputBuffer()
        inputBuffer = DecoderInputBuffer()
        super.init(queue: queue, trackType: .audio, clock: clock)

        self.audioSink.delegate = self
    }

    override func getMediaClock() -> MediaClock? { self }

    override func getCapabilities() -> any RendererCapabilities {
        Decoder.getCapabilities()
    }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        if outputStreamEnded {
            do {
                try audioSink.playToEndOfStream()
                nextBufferToWritePresentationTime = lastBufferInStreamPresentationTime
            } catch {
                throw error
            }

            return
        }

        if inputFormat == nil {
            flagsOnlyBuffer.reset()

            switch try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat) {
            case let .didReadFormat(format):
                try onInputFormatChanged(format: format)
            case .didReadBuffer:
                assert(flagsOnlyBuffer.flags.contains(.endOfStream))
                inputStreamEnded = true
                do {
                    try processEndOfStream()
                } catch {
                    throw error
                }
                return
            case .nothingRead:
                return
            }
        }

        try maybeInitDecoder()

        if decoder != nil {
            while try drainOutputBuffer(position: position, elapsedRealtime: elapsedRealtime) {}
            while try feedInputBuffer() {}
        }
    }

    override func isEnded() -> Bool {
        outputStreamEnded && audioSink.isEnded()
    }

    override func onStreamChanged(formats: [CMFormatDescription], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
        try super.onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
        firstStreamSampleRead = false
        if self.startPosition == nil {
            self.startPosition = startPosition
        }
        self.outputStreamOffset = offset
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        audioSink.flush()

        currentPosition = position
        nextBufferToWritePresentationTime = nil
        allowPositionDiscontinuity = true
        inputStreamEnded = false
        outputStreamEnded = false
        initialPosition = nil
        if decoder != nil {
            try flushDecoder()
        }
        try super.onPositionReset(position: position, joining: joining)
    }

    override func isReady() -> Bool {
        return audioSink.hasPendingData() || super.isReady()
    }

    override func onStarted() throws {
        try super.onStarted()
        audioSink.play()
    }

    override func onStopped() {
        super.onStopped()
        audioSink.pause()
    }

    override func onDisabled() {
        inputFormat = nil
        audioTrackNeedsConfigure = true
        outputStreamOffset = nil
        nextBufferToWritePresentationTime = nil
        releaseDecoder()
        audioSink.reset()
        super.onDisabled()
    }

    override func onReset() {
        super.onReset()
        startPosition = nil
    }

    private func processEndOfStream() throws {
        outputStreamEnded = true
        try audioSink.playToEndOfStream()
        nextBufferToWritePresentationTime = lastBufferInStreamPresentationTime
    }

    private func flushDecoder() throws {
        buffersInCodecCount = 0
        if decoderReinitializationState != .none {
            releaseDecoder()
            try maybeInitDecoder()
        } else {
            inputBuffer.reset()
            outputBuffer = nil
            decoder?.flush()
            decoderReceivedBuffers = false
        }
    }

    private func releaseDecoder() {
        inputBuffer.reset()
        outputBuffer = nil
        decoderReinitializationState = .none
        decoderReceivedBuffers = false
        buffersInCodecCount = 0

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
        let decoder = try createDecoder(format: inputFormat)
        self.decoder = decoder
    }

    func createDecoder(format: CMFormatDescription) throws -> Decoder {
        let decoder = try decoderFactory.create(type: Decoder.self, queue: queue, format: format)
        return decoder as! Decoder
    }

    func onInputFormatChanged(format: CMFormatDescription) throws {
        waitingForFirstSampleInFormat = true
        let oldFormat = inputFormat
        inputFormat = format

        if decoder == nil {
            try maybeInitDecoder()
            return
        }

        let reuseResult = canReuseDecoder(oldFormat: oldFormat, newFormat: format)
        if !reuseResult {
            if decoderReceivedBuffers {
                decoderReinitializationState = .signalEndOfStream
            } else {
                releaseDecoder()
                try maybeInitDecoder()
            }
        }
    }

    override func setPlaybackSpeed(current: Float, target: Float) throws {
        try super.setPlaybackSpeed(current: current, target: target)
    }

    private func drainOutputBuffer(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        if outputBuffer == nil {
            outputBuffer = decoder?.dequeueOutputBuffer()
            guard let outputBuffer else { return false }

            if let sampleBuffer = outputBuffer.audioBuffer, sampleBuffer.numSamples <= 0 {
                audioSink.handleDiscontinuity()
            }

            if outputBuffer.sampleFlags.contains(.firstSample) {
                processFirstSampleOfStream()
            }
        }

        guard let outputBuffer else { return false }

        if outputBuffer.sampleFlags.contains(.endOfStream) {
            if decoderReinitializationState == .waitEndOfStream {
                releaseDecoder()
                try maybeInitDecoder()
                audioTrackNeedsConfigure = true
            } else {
                self.outputBuffer = nil
                try processEndOfStream()
            }
            
            return false
        }

        guard let sampleBuffer = outputBuffer.audioBuffer,
              let inputFormat = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
            self.outputBuffer = nil
            return false
        }

        nextBufferToWritePresentationTime = nil
        if !audioTrackNeedsConfigure {
            try audioSink.configure(inputFormat: inputFormat)
            audioTrackNeedsConfigure = false
        }

        if try audioSink.handleBuffer(sampleBuffer, presentationTime: outputBuffer.presentationTime) {
            self.outputBuffer = nil
            return true
        } else {
            nextBufferToWritePresentationTime = outputBuffer.presentationTime
            return false
        }
    }

    private func processFirstSampleOfStream() {
        audioSink.handleDiscontinuity()

        // TODO: pendingStreamOffset
    }

//    private func setOutputStreamOffset(_ outputStreamOffset: Int64?) {
//        self.outputStreamOffset = outputStreamOffset
//    }

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
            try decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
            resetInputBuffer()
            decoderReinitializationState = .waitEndOfStream
            return false
        }

        switch try readSource(to: inputBuffer) {
        case let .didReadFormat(format):
            try onInputFormatChanged(format: format)
            return true
        case .didReadBuffer:
            if inputBuffer.flags.contains(.endOfStream) {
                inputStreamEnded = true
                lastBufferInStreamPresentationTime = largestQueuedPresentationTime
                try decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
                resetInputBuffer()
                return false
            }

            if !firstStreamSampleRead {
                firstStreamSampleRead = true
                inputBuffer.flags.insert(.firstSample)
            }
            largestQueuedPresentationTime = inputBuffer.time
            if didReadStreamToEnd() || inputBuffer.flags.contains(.lastSample) {
                lastBufferInStreamPresentationTime = largestQueuedPresentationTime
            }

            try decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
            buffersInCodecCount += 1
            decoderReceivedBuffers = true
            resetInputBuffer()
            return true
        case .nothingRead:
            if didReadStreamToEnd() {
                lastBufferInStreamPresentationTime = largestQueuedPresentationTime
            }
            return false
        }
    }
}

extension AudioQueueRenderer: AudioSinkDelegate {
    func onPositionDiscontinuity() {
        allowPositionDiscontinuity = true
    }
}

extension AudioQueueRenderer: MediaClock {
    func getPosition() -> Int64 {
        updateCurrentPosition()
        return currentPosition
    }

    private func updateCurrentPosition() {
        guard let newCurrentPosition = audioSink.getPosition() else {
            return
        }
        currentPosition = allowPositionDiscontinuity ? newCurrentPosition : max(currentPosition, newCurrentPosition)
        allowPositionDiscontinuity = false
    }

    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        audioSink.setPlaybackParameters(new: playbackParameters)
    }

    func getPlaybackParameters() -> PlaybackParameters {
        audioSink.getPlaybackParameters()
    }
}

extension AudioQueueRenderer {
    func resetInputBuffer() {
        inputIndex = nil
        inputBuffer.reset()
    }
}
