//
//  AVFVideoRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 09.01.2026.
//

import AVFoundation
import VideoToolbox

final class AVFVideoRenderer: BaseSERenderer {
    private let queue: Queue
    private let formatQueue: TimedValueQueue<Format>
    private let renderersStorage: VideoSampleBufferRenderersStorage
    private let allowedJoiningTimeMs: Int64
    private let maxDroppedFramesToNotify: Int
    private let flagsOnlyBuffer: DecoderInputBuffer

    private var inputFormat: Format?
    private var outputFormat: Format?
    private var outputFormatDescription: CMFormatDescription?
    private var decoder: VTDecoder?
    private var inputBuffer: DecoderInputBuffer?
    private var outputBuffer: VTDecoderOutputBuffer?
    private var decoderReinitializationState = DecoderReinitializationState.none
    private var decoderReceivedBuffers = false
    private var firstFrameState: FirstFrameState = .notRenderedOnlyAllowedIfStarted
    private var initialPositionUs = Int64.zero
    private var joiningDeadlineMs: Int64
    private var waitingForFirstSampleInFormat = false
    private var inputStreamEnded = false
    private var outputStreamEnded = false

    private var droppedFrameAccumulationStartTimeMs = Int64.zero
    private var droppedFrames = 0
    private var consecutiveDroppedFrameCount = 0
    private var buffersInCodecCount = 0
    private var lastRenderTimeUs = Int64.zero
    private var requestMediaDataInfo: (Queue, () -> Void)?

    init(
        queue: Queue,
        clock: SEClock,
        allowedJoiningTimeMs: Int64,
        maxDroppedFramesToNotify: Int
    ) {
        self.queue = queue
        formatQueue = .init()
        renderersStorage = .init(queue: queue)
        self.allowedJoiningTimeMs = allowedJoiningTimeMs
        self.maxDroppedFramesToNotify = maxDroppedFramesToNotify
        flagsOnlyBuffer = .noDataBuffer()
        joiningDeadlineMs = .timeUnset

        super.init(queue: queue, trackType: .video, clock: clock)
    }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        RendererCapabilities.Support(
            formatSupport: try VTDecoder.supportsFormat(format),
            adaptiveSupport: .notSeamless,
            hardwareAccelerationSupport: .supported,
            decoderSupport: .primary,
            tunnelingSupport: .supported
        )
    }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        guard !outputStreamEnded else { return }

        if inputFormat == nil {
            flagsOnlyBuffer.clear()
            let result = try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)

            if case let .didReadFormat(format) = result {
                try onInputFormatChanged(format)
            } else if case .didReadBuffer = result {
                assert(flagsOnlyBuffer.flags.contains(.endOfStream))
                inputStreamEnded = true
                outputStreamEnded = true
                return
            } else {
                return
            }
        }

        try maybeInitDecoder()

        if decoder != nil {
            while try drainOutputBuffer(positionUs: position, elapsedRealtimeUs: elapsedRealtime) {}
            while try feedInputBuffer() {}
        }
    }

    override func isEnded() -> Bool {
        outputStreamEnded
    }

    override func isReady() -> Bool {
        if inputFormat != nil, (isSourceReady() || outputBuffer != nil),
           (firstFrameState == .rendered || !renderersStorage.hasOutput) {
            joiningDeadlineMs = .timeUnset
            // Ready. If we were joining then we've now joined, so clear the joining deadline.
            return true
        } else if joiningDeadlineMs == .timeUnset {
            // Not joining.
            return false
        } else if getClock().milliseconds < joiningDeadlineMs {
            // Joining and still within the joining deadline.
            return true
        } else {
            // The joining deadline has been exceeded. Give up and clear the deadline.
            joiningDeadlineMs = .timeUnset
            return false
        }
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setVideoOutput(renderer):
            let didHasRenderers = renderersStorage.hasOutput
            renderersStorage.addRenderer(renderer)
            if !didHasRenderers {
                onOutputChanged()
            }
        case let .removeVideoOutput(renderer):
            renderersStorage.removeRenderer(renderer)
            if !renderersStorage.hasOutput {
                onOutputRemoved()
            }
        case let .setControlTimebase(timebase):
            renderersStorage.setControlTimebase(timebase)
        case let .requestMediaDataWhenReady(queue, block):
            requestMediaDataInfo = (queue, block)
            renderersStorage.requestMediaDataWhenReady(on: queue.queue) { [unowned self] in
                renderersStorage.stopRequestingMediaData()
                block()
            }
        case .stopRequestingMediaData:
            requestMediaDataInfo = nil
            renderersStorage.stopRequestingMediaData()
        default:
            try super.handleMessage(message)
        }
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        // TODO: decoder counters
        firstFrameState = mayRenderStartOfStream ? .notRendered : .notRenderedOnlyAllowedIfStarted
    }

    override func enableRenderStartOfStream() {
        if firstFrameState == .notRenderedOnlyAllowedIfStarted {
            firstFrameState = .notRendered
        }
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        inputStreamEnded = false
        outputStreamEnded = false
        lowerFirstFrameState(.notRendered)
        initialPositionUs = .timeUnset
        consecutiveDroppedFrameCount = 0
        if decoder != nil {
            try flushDecoder()
        }
        renderersStorage.flush()

        if joining {
            setJoiningDeadlineMs()
        } else {
            joiningDeadlineMs = .timeUnset
        }

        if formatQueue.size > 0 {
            waitingForFirstSampleInFormat = true
        }
        formatQueue.clear()
    }

    override func onStarted() throws {
        droppedFrames = 0
        droppedFrameAccumulationStartTimeMs = getClock().milliseconds
        lastRenderTimeUs = getClock().microseconds
    }

    override func onStopped() {
        joiningDeadlineMs = .timeUnset
        // TODO: maybeNotifyDroppedFrames()
    }

    override func onDisabled() {
        inputFormat = nil
        // TODO: reportedVideoSize = nil
        lowerFirstFrameState(.notRenderedOnlyAllowedIfStarted)
        renderersStorage.flush(removeImage: true)
        releaseDecoder()
    }

    func flushDecoder() throws {
        renderersStorage.flush()
        buffersInCodecCount = 0
        if decoderReinitializationState != .none {
            releaseDecoder()
            try maybeInitDecoder()
        } else {
            inputBuffer = nil
            outputBuffer?.release()
            outputBuffer = nil
            decoder?.flush()
            decoder?.setOutputStartTimeUs(getLastResetPosition())
            decoderReceivedBuffers = false
        }
    }

    func releaseDecoder() {
        inputBuffer = nil
        outputBuffer = nil
        decoderReinitializationState = .none
        decoderReceivedBuffers = false
        buffersInCodecCount = 0
        decoder?.release()
        decoder = nil
    }

    func onInputFormatChanged(_ newFormat: Format) throws {
        waitingForFirstSampleInFormat = true
        let oldFormat = inputFormat
        inputFormat = newFormat
        outputFormatDescription = nil

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

    private func onProcessedOutputBuffer(presentationTimeUs: Int64) { buffersInCodecCount -= 1 }

    private func shouldDropOutputBuffer(earlyUs: Int64, elapsedRealtimeUs: Int64) -> Bool {
        isBufferLate(earlyUs: earlyUs)
    }

    private func shouldDropBuffersToKeyframe(earlyUs: Int64, elapsedRealtimeUs: Int64) -> Bool {
        isBufferVeryLate(earlyUs: earlyUs)
    }

    private func skipOutputBuffer(_ outputBuffer: VTDecoderOutputBuffer) {
        // TODO: decoder counters
        outputBuffer.release()
    }

    private func dropOutputBuffer(_ outputBuffer: VTDecoderOutputBuffer) {
        // TODO: decoder counters
        outputBuffer.release()
    }

    private func maybeDropBuffersToKeyframe(positionUs: Int64) throws -> Bool {
        let droppedSourceBufferCount = skipSource(position: positionUs)
        if droppedSourceBufferCount == 0 {
            return false
        }

        // TODO: decoderCounters
        // We dropped some buffers to catch up, so update the decoder counters and flush the decoder,
        // which releases all pending buffers buffers including the current output buffer.
        updateDroppedBufferCounters(
            droppedInputBufferCount: droppedSourceBufferCount,
            droppedDecoderBufferCount: buffersInCodecCount
        )

        try flushDecoder()
        return true
    }

    private func updateDroppedBufferCounters(
        droppedInputBufferCount: Int,
        droppedDecoderBufferCount: Int
    ) {
        // TODO: decoderCounters
    }

    private func createDecoder(format: Format) throws -> VTDecoder {
        return try VTDecoder(format: format)
    }

    private func renderOutputBuffer(outputBuffer: VTDecoderOutputBuffer, presentationTimeUs: Int64) throws {
        lastRenderTimeUs = getClock().microseconds
        if presentationTimeUs < getLastResetPosition() {
            outputBuffer.release(); return
        }

        guard let pixelBuffer = outputBuffer.pixelBuffer else {
            dropOutputBuffer(outputBuffer); return
        }

        let outputFormatDescription = try CMFormatDescription(imageBuffer: pixelBuffer)
        let sampleBuffer = try CMSampleBuffer(
            imageBuffer: pixelBuffer,
            formatDescription: outputFormatDescription,
            sampleTiming: .init(
                duration: .invalid,
                presentationTimeStamp: .from(microseconds: presentationTimeUs),
                decodeTimeStamp: .invalid
            )
        )

        renderersStorage.enqueue(sampleBuffer)
        outputBuffer.release()
        consecutiveDroppedFrameCount = 0
        maybeNotifyRenderedFirstFrame()

        if !renderersStorage.isReadyForMoreMediaData, let (queue, block) = requestMediaDataInfo {
            try handleMessage(.requestMediaDataWhenReady(queue: queue, block: block))
        }
    }

    private func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool {
        decoder?.canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) ?? false
    }

    private func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }

        decoder = try createDecoder(format: inputFormat)
        decoder?.setOutputStartTimeUs(getLastResetPosition())
    }

    private func feedInputBuffer() throws -> Bool {
        guard let decoder,
              decoderReinitializationState != .waitEndOfStream,
              !inputStreamEnded else {
            // We need to reinitialize the decoder or the input stream has ended.
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
            return false
        case let .didReadFormat(format):
            try onInputFormatChanged(format)
            return true
        case .didReadBuffer:
            if inputBuffer.flags.contains(.endOfStream) {
                inputStreamEnded = true
                try decoder.queueInputBuffer(inputBuffer)
                self.inputBuffer = nil
                return false
            }

            if waitingForFirstSampleInFormat {
                formatQueue.add(timestamp: inputBuffer.timeUs, value: inputFormat!) // TODO: make error
                waitingForFirstSampleInFormat = false
            }

            inputBuffer.format = inputFormat
            try decoder.queueInputBuffer(inputBuffer)

            // TODO: Not working properly
//            if let minimumUpcomingPts = decoder.firstPresentationTimeStamp {
//                renderersStorage.setPresentationTimeExpectation(
//                    .minimumUpcoming(minimumUpcomingPts)
//                )
//            }

            buffersInCodecCount += 1
            decoderReceivedBuffers = true
            // TODO: decoder counters
            self.inputBuffer = nil
            return true
        }
    }

    private func drainOutputBuffer(positionUs: Int64, elapsedRealtimeUs: Int64) throws -> Bool {
        if outputBuffer == nil {
            guard let decoder else { return false }
            outputBuffer = try decoder.dequeueOutputBuffer()
            if outputBuffer == nil {
                return false
            }

            // TODO: decoder counters
            buffersInCodecCount -= outputBuffer?.skippedOutputBufferCount ?? 0
        }

        guard let outputBuffer else { return false }

        if outputBuffer.sampleFlags.contains(.endOfStream) {
            if decoderReinitializationState == .waitEndOfStream {
                releaseDecoder()
                try maybeInitDecoder()
            } else {
                outputBuffer.release()
                self.outputBuffer = nil
                outputStreamEnded = true
            }

            return false
        }

        let bufferTime = outputBuffer.timeUs
        let processedOutputBuffer = try processOutputBuffer(outputBuffer, positionUs: positionUs, elapsedRealtimeUs: elapsedRealtimeUs)
        if processedOutputBuffer {
            onProcessedOutputBuffer(presentationTimeUs: bufferTime)
            self.outputBuffer = nil
        }

        return processedOutputBuffer
    }

    private func processOutputBuffer(
        _ outputBuffer: VTDecoderOutputBuffer,
        positionUs: Int64,
        elapsedRealtimeUs: Int64
    ) throws -> Bool {
        if initialPositionUs == .timeUnset {
            initialPositionUs = positionUs
        }

        let bufferTimeUs = outputBuffer.timeUs
        let earlyUs = bufferTimeUs - positionUs

        if !renderersStorage.hasOutput {
            // Skip frames in sync with playback, so we'll be at the right frame if the mode changes.
            if isBufferLate(earlyUs: earlyUs) {
                skipOutputBuffer(outputBuffer)
                return true
            }

            return false
        }

        let format = formatQueue.pollFloor(timestamp: bufferTimeUs)
        if format != nil {
            outputFormat = format
        } else {
            // After a stream change or after the initial start, there should be an input format change
            // which we've not found. Check the Format queue in case the corresponding presentation
            // timestamp is greater than bufferTimeUs
            outputFormat = formatQueue.pollFirst()
        }

        let presentationTimeUs = bufferTimeUs //- getStreamOffset()
        if try! shouldForceRender(earlyUs: earlyUs) {
            try! renderOutputBuffer(outputBuffer: outputBuffer, presentationTimeUs: presentationTimeUs)
            return true
        }

        let isStarted = getState() == .started
        if !isStarted || positionUs == initialPositionUs {
            return false
        }

        // TODO: Treat dropped buffers as skipped while we are joining an ongoing playback.
        if shouldDropBuffersToKeyframe(earlyUs: earlyUs, elapsedRealtimeUs: elapsedRealtimeUs),
           try! maybeDropBuffersToKeyframe(positionUs: positionUs) {
            return false
        } else if shouldDropOutputBuffer(earlyUs: earlyUs, elapsedRealtimeUs: elapsedRealtimeUs) {
            dropOutputBuffer(outputBuffer)
            return true
        }

        if earlyUs < 30000 {
            try! renderOutputBuffer(outputBuffer: outputBuffer, presentationTimeUs: presentationTimeUs)
            return true
        }

        return false
    }

    private func shouldForceRender(earlyUs: Int64) throws -> Bool {
        let isStarted = getState() == .started
        switch firstFrameState {
        case .notRenderedOnlyAllowedIfStarted:
            return isStarted
        case .notRendered:
            return true
        case .rendered:
            return renderersStorage.isReadyForMoreMediaData && isStarted
        default:
            throw ErrorBuilder(errorDescription: "Wrong State")
        }
    }

    private func onOutputChanged() {
        // TODO: maybeRenotifyVideoSizeChanged()
        // We haven't rendered to the new output yet.
        lowerFirstFrameState(.notRendered)
        if getState() == .started {
            setJoiningDeadlineMs()
        }
    }

    private func onOutputRemoved() {
        lowerFirstFrameState(.notRendered)
    }

    private func onOutputReset() {
        // TODO: maybeRenotifyVideoSizeChanged()
        // TODO: maybeRenotifyRenderedFirstFrame()
    }

    private func setJoiningDeadlineMs() {
        joiningDeadlineMs = if allowedJoiningTimeMs > 0 {
            getClock().milliseconds + allowedJoiningTimeMs
        } else {
            .timeUnset
        }
    }

    private func lowerFirstFrameState(_ firstFrameState: FirstFrameState) {
        self.firstFrameState = min(self.firstFrameState, firstFrameState)
    }

    private func maybeNotifyRenderedFirstFrame() {
        if firstFrameState != .rendered {
            firstFrameState = .rendered
            // TODO: notify
        }
    }

    private func isBufferLate(earlyUs: Int64) -> Bool {
        // Class a buffer as late if it should have been presented more than 30 ms ago.
        return earlyUs < -30000
    }

    private func isBufferVeryLate(earlyUs: Int64) -> Bool {
        // Class a buffer as very late if it should have been presented more than 500 ms ago.
        return earlyUs < -500000
    }
}

extension AVFVideoRenderer: VideoSampleBufferRendererDelegate {
    nonisolated var isolation: any Actor {
        queue.playerActor()
    }

    func renderer(_ renderer: VideoSampleBufferRenderer, didFailedRenderingWith error: Error?, isolation: isolated any Actor) {
        assert(queue.isCurrent())
    }
}

private extension AVFVideoRenderer {
    enum FirstFrameState: Comparable {
        case notRenderedOnlyAllowedIfStarted
        case notRendered
        case notRenderedAfterStreamChange
        case rendered
    }
}
