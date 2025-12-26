//
//  AudioQueueRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 24.04.2025.
//

import AVFoundation

protocol AVFAudioRendererDecoder: SEDecoder where OutputBuffer: AQOutputBuffer {
    static func getCapabilities() -> RendererCapabilities
    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool
}

protocol AQOutputBuffer: DecoderOutputBuffer {
    var audioBuffer: CMSampleBuffer? { get }
}

final class AVFAudioRenderer<Decoder: AVFAudioRendererDecoder>: BaseSERenderer {
    var volume: Float {
        get { audioSink.volume }
        set { audioSink.volume = newValue }
    }

    private var decoder: Decoder?
    private let audioSink: IAudioSink
    private let queue: Queue
    private let decoderFactory: SEDecoderFactory

    private let flagsOnlyBuffer: DecoderInputBuffer
    private var inputFormat: Format?

    private var inputIndex: Int?
    private var inputBuffer: DecoderInputBuffer
    private var outputBuffer: AQOutputBuffer?
    private var outputFormatDescription: CMFormatDescription?

    private var decoderReinitializationState: DecoderReinitializationState = .none
    private var decoderReceivedBuffers = false
    private var audioTrackNeedsConfigure = true

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

    init(
        queue: Queue,
        clock: SEClock,
        audioSink: IAudioSink? = nil,
        renderSynchronizer: AVSampleBufferRenderSynchronizer,
        decoderFactory: SEDecoderFactory
    ) throws {
        self.queue = queue
//        self.audioSink = audioSink ?? AudioSink(queue: queue, clock: clock)
        self.audioSink = audioSink ?? TestAudioSink(queue: queue, renderSynchronizer: renderSynchronizer)//AudioSink(queue: queue, clock: clock)
        self.decoderFactory = decoderFactory
        outputSampleQueue = try! TypedCMBufferQueue<CMSampleBuffer>()
        flagsOnlyBuffer = DecoderInputBuffer()
        inputBuffer = DecoderInputBuffer()
        super.init(queue: queue, trackType: .audio, clock: clock)

        self.audioSink.delegate = self
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .requestMediaDataWhenReady(queue, block) = message {
            audioSink.requestMediaDataWhenReady(on: queue, block: block)
        } else if case .stopRequestingMediaData = message {
            audioSink.stopRequestingMediaData()
        } else if case let .setAudioVolume(volume) = message {
            audioSink.volume = volume
        } else if case let .setAudioIsMuted(isMuted) = message {
            // TODO: audioSink.isMuted = isMuted
        } else {
            try super.handleMessage(message)
        }
    }

    override func getMediaClock() -> MediaClock? { self }

    override func getTimebase() -> CMTimebase? { audioSink.timebase }

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

    override func onStreamChanged(formats: [Format], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
        try! super.onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
        firstStreamSampleRead = false
        if self.startPosition == nil {
            self.startPosition = startPosition
        }
        self.outputStreamOffset = offset
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        audioSink.flush(reuse: true)

        currentPosition = position
        nextBufferToWritePresentationTime = nil
        allowPositionDiscontinuity = true
        inputStreamEnded = false
        outputStreamEnded = false
        initialPosition = nil
        if decoder != nil {
            try! flushDecoder()
        }
        try! super.onPositionReset(position: position, joining: joining)
    }

    override func isReady() -> Bool {
        return audioSink.hasPendingData() || super.isReady()
    }

    override func onStarted() throws {
        try! super.onStarted()
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
        try? outputSampleQueue.reset()
        super.onDisabled()
    }

    override func onReset() {
        super.onReset()
        startPosition = nil
    }

    private func processEndOfStream() throws {
        outputStreamEnded = true
        try! audioSink.playToEndOfStream()
        nextBufferToWritePresentationTime = lastBufferInStreamPresentationTime
    }

    private func flushDecoder() throws {
        buffersInCodecCount = 0
        try! outputSampleQueue.reset()
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

        if let decoder {
            decoder.release()
            self.decoder = nil
        }
    }
    
    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        decoder?.canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) ?? false
    }

    func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }
        let decoder = try! createDecoder(format: inputFormat)
        self.decoder = decoder
    }

    func createDecoder(format: Format) throws -> Decoder {
        return try! decoderFactory.create(type: Decoder.self, queue: queue, format: format)
    }

    func onInputFormatChanged(format: Format) throws {
        waitingForFirstSampleInFormat = true
        outputFormatDescription = nil
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
                audioTrackNeedsConfigure = true
            }
        }
    }

    override func setPlaybackSpeed(current: Float, target: Float) throws {
        try! super.setPlaybackSpeed(current: current, target: target)
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
                try! processEndOfStream()
            }
            
            return false
        }

        guard let sampleBuffer = outputBuffer.audioBuffer,
              let inputFormat = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
            self.outputBuffer = nil
            return false
        }

        nextBufferToWritePresentationTime = nil
        if audioTrackNeedsConfigure {
            try audioSink.configure(
                inputFormat: inputFormat,
                channelLayout: sampleBuffer.formatDescription?.audioChannelLayout
            )
            audioTrackNeedsConfigure = false
        }

        let updatedSampleBuffer = try CMSampleBuffer(
            copying: sampleBuffer,
            withNewTiming: [
                CMSampleTimingInfo(
                    duration: .invalid,
                    presentationTimeStamp: CMTime.from(microseconds: outputBuffer.presentationTime),
                    decodeTimeStamp: .invalid
                )
            ]
        )
        if try audioSink.handleBuffer(updatedSampleBuffer, presentationTime: outputBuffer.presentationTime) {
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
                lastBufferInStreamPresentationTime = largestQueuedPresentationTime
                try! decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
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

            try! decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
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

extension AVFAudioRenderer: AudioSinkDelegate {
    func onPositionDiscontinuity() {
        allowPositionDiscontinuity = true
    }
}

extension AVFAudioRenderer: MediaClock {
    func getPositionUs() -> Int64 {
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

extension AVFAudioRenderer {
    func resetInputBuffer() {
        inputIndex = nil
        inputBuffer.reset()
    }
}
