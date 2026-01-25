//
//  AVFAudioRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.01.2026.
//

import AVFoundation

final class AVFAudioRenderer: BaseSERenderer {
    private let queue: Queue
    private let renderSynchronizer: AVSampleBufferRenderSynchronizer
    private let audioRenderer: AVSampleBufferAudioRenderer

    private let flagsOnlyBuffer: DecoderInputBuffer
    private var inputFormat: Format?
    private var firstStreamSampleRead: Bool = false

    private var decoder: AudioConverterDecoder?
    private var inputBuffer: ACDecoderInputBuffer?
    private var outputBuffer: ACDecoderOutputBuffer?

    private var decoderReinitializationState: DecoderReinitializationState
    private var decoderReceivedBuffers: Bool = false

    private var currentPositionUs: Int64 = .zero
    private var allowPositionDiscontinuity: Bool = false
    private var inputStreamEnded: Bool = false
    private var outputStreamEnded: Bool = false
    private var outputStreamOffsetUs: Int64 = .zero
    private var pendingOutputStreamOffsetsUs: [Int64]
    private var pendingOutputStreamOffsetCount: Int = 0
//    private var hasPendingReportedSkippedSilence: Bool = false
    private var isStarted: Bool = false
    private var largestQueuedPresentationTimeUs: Int64
    private var lastBufferInStreamPresentationTimeUs: Int64
    private var nextBufferToWritePresentationTimeUs: Int64

    private var diffTest: Int64 = .zero
    private var didResetPosition: Bool = false
    private var waitingForEndOfStream: Bool = false
    private var streamEnded: Bool = false
    private var timeObserver: Any?
    private var playbackParameters: PlaybackParameters = .default
    private var requestMediaDataInfo: (Queue, () -> Void)?

    init(
        queue: Queue,
        renderSynchronizer: AVSampleBufferRenderSynchronizer,
        clock: SEClock
    ) {
        self.queue = queue
        self.renderSynchronizer = renderSynchronizer
        audioRenderer = AVSampleBufferAudioRenderer()

        flagsOnlyBuffer = .noDataBuffer()
        decoderReinitializationState = .none
        pendingOutputStreamOffsetsUs = Array(repeating: 0, count: 10)
        largestQueuedPresentationTimeUs = .timeUnset
        lastBufferInStreamPresentationTimeUs = .timeUnset
        nextBufferToWritePresentationTimeUs = .timeUnset

        super.init(queue: queue, trackType: .audio, clock: clock)

        setOutputStreamOffsetUs(.timeUnset)

        renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        renderSynchronizer.addRenderer(audioRenderer)
    }

    override func getTimebase() -> TimebaseSource? {
        .renderSynchronizer(renderSynchronizer)
    }

    override func getMediaClock() -> MediaClock? { self }
    override func getCapabilities() -> RendererCapabilities { self }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        if outputStreamEnded {
            try playEndOfStream()
            nextBufferToWritePresentationTimeUs = lastBufferInStreamPresentationTimeUs
            return
        }

        if inputFormat == nil {
            flagsOnlyBuffer.clear()
            let result = try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)

            if case let .didReadFormat(format) = result {
                try onInputFormatChanged(format)
            } else if result == .didReadBuffer {
                assert(flagsOnlyBuffer.flags.contains(.endOfStream))
                inputStreamEnded = true

                do {
                    try processEndOfStream()
                } catch {
                    throw error
                }
            } else {
                return
            }
        }

        try maybeInitDecoder()

        guard let decoder else { return }

        do {
            while try drainOutputBuffer() {}
            while try feedInputBuffer() {}
        } catch {
            throw error
        }
    }

    private func drainOutputBuffer() throws -> Bool {
        guard let decoder else { return false }

        if outputBuffer == nil {
            outputBuffer = try decoder.dequeueOutputBuffer()

            guard let outputBuffer else { return false }
            if outputBuffer.skippedOutputBufferCount > 0 {
                // TODO: decoder counters
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
            } else {
                outputBuffer.release()
                self.outputBuffer = nil
                try processEndOfStream()
            }
            return false
        }

        nextBufferToWritePresentationTimeUs = .timeUnset
        guard let sampleBuffer = outputBuffer.sampleBuffer else { return false }
        if audioRenderer.isReadyForMoreMediaData {
            if didResetPosition {
                renderSynchronizer.setRate(
                    renderSynchronizer.rate,
                    time: .from(microseconds: outputBuffer.timeUs)
                )
                didResetPosition = false
            }

            audioRenderer.enqueue(sampleBuffer)
            // TODO: decoderCounters.renderedOutputBufferCount
            outputBuffer.release()
            self.outputBuffer = nil
            return true
        } else {
            nextBufferToWritePresentationTimeUs = outputBuffer.timeUs

            if let (queue, block) = requestMediaDataInfo {
                try handleMessage(.requestMediaDataWhenReady(queue: queue, block: block))
            }
        }

        return false
    }

    private func processFirstSampleOfStream() {
        if pendingOutputStreamOffsetCount != 0 {
            setOutputStreamOffsetUs(pendingOutputStreamOffsetsUs[0])
            pendingOutputStreamOffsetCount -= 1
            pendingOutputStreamOffsetsUs.replaceSubrange(
                0..<pendingOutputStreamOffsetCount,
                with: pendingOutputStreamOffsetsUs[1..<(1 + pendingOutputStreamOffsetCount)]
            )
        }
    }

    private func setOutputStreamOffsetUs(_ outputStreamOffsetUs: Int64) {
        self.outputStreamOffsetUs = outputStreamOffsetUs
    }

    private func feedInputBuffer() throws -> Bool {
        guard let decoder else { return false }

        if decoderReinitializationState == .waitEndOfStream || inputStreamEnded {
            return false
        }

        if inputBuffer == nil {
            inputBuffer = try decoder.dequeueInputBuffer()
        }

        guard let inputBuffer else { return false }

        if decoderReinitializationState == .signalEndOfStream {
            inputBuffer.flags.insert(.endOfStream)
            try decoder.queueInputBuffer(inputBuffer)
            self.inputBuffer = nil
            decoderReinitializationState = .waitEndOfStream
            return false
        }

        switch try readSource(to: inputBuffer) {
        case .nothingRead:
            if didReadStreamToEnd() {
                lastBufferInStreamPresentationTimeUs = largestQueuedPresentationTimeUs
            }

            return false
        case let .didReadFormat(format):
            try onInputFormatChanged(format)
            return true
        case .didReadBuffer:
            if inputBuffer.flags.contains(.endOfStream) {
                inputStreamEnded = true
                if lastBufferInStreamPresentationTimeUs != .timeUnset {
                    diffTest = lastBufferInStreamPresentationTimeUs - largestQueuedPresentationTimeUs
                }
                lastBufferInStreamPresentationTimeUs = largestQueuedPresentationTimeUs
                try decoder.queueInputBuffer(inputBuffer)
                self.inputBuffer = nil
                return false
            }

            if !firstStreamSampleRead {
                firstStreamSampleRead = true
                inputBuffer.flags.insert(.firstSample)
            }

            largestQueuedPresentationTimeUs = inputBuffer.timeUs
            if didReadStreamToEnd() || inputBuffer.flags.contains(.lastSample) {
                lastBufferInStreamPresentationTimeUs = largestQueuedPresentationTimeUs
            }

            inputBuffer.format = inputFormat
            try decoder.queueInputBuffer(inputBuffer)
            decoderReceivedBuffers = true
            // TODO: decoderCounters.queuedInputBufferCount += 1
            self.inputBuffer = nil
            return true
        }
    }

    private func processEndOfStream() throws {
        outputStreamEnded = true
        try playEndOfStream()
        nextBufferToWritePresentationTimeUs = lastBufferInStreamPresentationTimeUs
    }

    private func flushDecoder() throws {
        if decoderReinitializationState == .none {
            releaseDecoder()
            try maybeInitDecoder()
        } else {
            inputBuffer = nil
            outputBuffer?.release()
            outputBuffer = nil
            decoder?.flush()
            decoder?.setOutputStartTimeUs(getLastResetPosition())
        }
    }

    override func isEnded() -> Bool {
        outputStreamEnded && streamEnded
    }

    override func isReady() -> Bool {
        audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        // TODO: decoderCounters = Dec..
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        audioRenderer.flush()
        didResetPosition = true
        streamEnded = false
        currentPositionUs = position
        nextBufferToWritePresentationTimeUs = .timeUnset
        allowPositionDiscontinuity = true
        inputStreamEnded = false
        outputStreamEnded = false
        if decoder != nil {
            try flushDecoder()
        }
    }

    override func onStarted() throws {
        renderSynchronizer.rate = playbackParameters.playbackRate
        isStarted = true
    }

    override func onStopped() {
        updateCurrentPosition()
        renderSynchronizer.rate = .zero
        isStarted = false
    }

    override func onDisabled() {
        inputFormat = nil
        setOutputStreamOffsetUs(.timeUnset)
        nextBufferToWritePresentationTimeUs = .timeUnset
        releaseDecoder()
        audioRenderer.flush()
        streamEnded = false
        if let timeObserver {
            renderSynchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    override func onStreamChanged(formats: [Format], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
        try super.onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
        firstStreamSampleRead = false
        if outputStreamOffsetUs == .timeUnset {
            setOutputStreamOffsetUs(offset)
        } else {
            if pendingOutputStreamOffsetCount == pendingOutputStreamOffsetsUs.count {
                // TODO: log
            } else {
                pendingOutputStreamOffsetCount += 1
            }

            pendingOutputStreamOffsetsUs[pendingOutputStreamOffsetCount - 1] = offset
        }
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setAudioVolume(volume):
            audioRenderer.volume = volume
        case let .setAudioIsMuted(isMuted):
            audioRenderer.isMuted = isMuted
        case let .requestMediaDataWhenReady(queue, block):
            requestMediaDataInfo = (queue, block)
            audioRenderer.requestMediaDataWhenReady(on: queue.queue) { [unowned self] in
                audioRenderer.stopRequestingMediaData()
                block()
            }
        case .stopRequestingMediaData:
            audioRenderer.stopRequestingMediaData()
            requestMediaDataInfo = nil
        default:
            try super.handleMessage(message)
        }
    }

    private func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }

        decoder = try createDecoder(format: inputFormat)
        decoder?.setOutputStartTimeUs(getLastResetPosition())
        // TODO: decoder counters
    }

    private func releaseDecoder() {
        inputBuffer = nil
        outputBuffer = nil
        decoderReinitializationState = .none
        decoderReceivedBuffers = false
        largestQueuedPresentationTimeUs = .timeUnset
        lastBufferInStreamPresentationTimeUs = .timeUnset

        decoder?.release()
        decoder = nil
    }

    private func onInputFormatChanged(_ newFormat: Format) throws {
        let oldFormat = inputFormat
        inputFormat = newFormat

        if decoder == nil {
            try maybeInitDecoder()
            return
        }

        if !canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) {
            if decoderReceivedBuffers {
                decoderReinitializationState = .signalEndOfStream
            } else {
                releaseDecoder()
                try maybeInitDecoder()
            }
        }
    }

    private func createDecoder(format: Format) throws -> AudioConverterDecoder {
        try AudioConverterDecoder(format: format)
    }

    private func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        guard let oldFormat,
              let oldFormatDescription = try? oldFormat.buildFormatDescription(),
              let newFormatDescription = try? newFormat.buildFormatDescription() else {
            return false
        }

        return oldFormatDescription.equalTo(newFormatDescription)
    }

    private func updateCurrentPosition() {
        let newCurrentPositionUs = renderSynchronizer.currentTime().microseconds
        if newCurrentPositionUs != .timeUnset {
            currentPositionUs = allowPositionDiscontinuity ? newCurrentPositionUs : max(currentPositionUs, newCurrentPositionUs)
            allowPositionDiscontinuity = false
        }
    }

    private func playEndOfStream() throws {
        guard !waitingForEndOfStream, !streamEnded else { return }
        waitingForEndOfStream = true

        timeObserver = renderSynchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime.from(microseconds: lastBufferInStreamPresentationTimeUs + diffTest))],
            queue: queue.queue
        ) { [weak self] in
            guard let self else { return }

            waitingForEndOfStream = false
            streamEnded = true

            if let timeObserver {
                renderSynchronizer.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }
    }
}

extension AVFAudioRenderer: MediaClock {
    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        self.playbackParameters = playbackParameters

        if renderSynchronizer.rate != 0 {
            renderSynchronizer.rate = playbackParameters.playbackRate
        }
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }

    func getPositionUs() -> Int64 {
        if getState() == .started {
            updateCurrentPosition()
        }

        return currentPositionUs
    }
}

extension AVFAudioRenderer: RendererCapabilities {
    func supportsFormat(_ format: Format) -> Bool {
        guard let formatDescription = try? format.buildFormatDescription(),
              formatDescription.mediaType == .audio else {
            return false
        }

        return AudioConverterDecoder.formatSupported(formatDescription)
    }
}
