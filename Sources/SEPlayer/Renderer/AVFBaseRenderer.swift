//
//  AVFDecoder.swift
//  SEPlayer
//
//  Created by tvrrp on 15.03.2026.
//

//import AVFoundation
//import Decoder
//
//public protocol AVFDecoder: Decoder where InputBuffer: DecoderInputBuffer, OutputBuffer: SimpleDecoderOutputBuffer {
//    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool
//}
//
//class AVFBaseRenderer<D: AVFDecoder>: BaseSERenderer {
//    var lowWaterMark: WaterMarkSource = .sampleCount(3)
//    var hightWaterMark: WaterMarkSource = .sampleCount(5)
//    var currentRendererError: Error?
//
//    private(set) var decoder: D?
//    private(set) var outputStreamEnded = false
//    private(set) var inputFormat: Format?
//
//    private let flagsOnlyBuffer: DecoderInputBuffer
//    private var inputBuffer: D.InputBuffer?
//    private var outputBuffer: D.OutputBuffer?
//    private var decoderReinitializationState: DecoderReinitializationState
//    private var decoderReceivedBuffers = false
//    private var inputStreamEnded = false
//    private var firstStreamSampleRead = false
//
//    private var workingOnDecodeLoop = false
//    private var workingInFeedDataLoop = false
//    private var workingInOutputDataLoop = false
//    private var decoderLowWaterMarkToken: CMBufferQueue.TriggerToken?
//    private var decoderHighWaterMarkToken: CMBufferQueue.TriggerToken?
//    private var decoderOutputBufferAvailable: CMBufferQueue.TriggerToken?
//    private var sampleQueueAvailabilityToken: QueueTriggerToken?
//
//    override init(queue: Queue, trackType: TrackType, clock: SEClock) {
//        flagsOnlyBuffer = DecoderInputBuffer(bufferReplacementMode: .disabled)
//        decoderReinitializationState = .none
//        super.init(queue: queue, trackType: trackType, clock: clock)
//    }
//
//    override func willChangeStream() throws {
//        try super.willChangeStream()
//        if let sampleStream = getStream(), let sampleQueueAvailabilityToken {
//            sampleStream.removeTrigger(sampleQueueAvailabilityToken)
//            self.sampleQueueAvailabilityToken = nil
//        }
//    }
//
//    override func onStreamChanged(formats: [Format], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
//        try super.onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
//
//        firstStreamSampleRead = false
//        feedInputBuffer2()
//        requestOutputMediaDataWhenReady {
//            print("requestOutputMediaDataWhenReady onStreamChanged")
//            self.drainOutputBuffer2()
//        }
//    }
//
//    override func onPositionReset(position: Int64, joining: Bool) throws {
//        inputStreamEnded = false
//        outputStreamEnded = false
//        firstStreamSampleRead = false
//        if decoder != nil { try flushDecoder() }
//        print("ON POSITION RESETTTT")
//        feedInputBuffer2()
//        requestOutputMediaDataWhenReady {
//            print("requestOutputMediaDataWhenReady from POS RESET")
//            self.drainOutputBuffer2()
//        }
//    }
//
//    override func onDisabled() {
//        inputFormat = nil
//        if let stream = getStream(), let sampleQueueAvailabilityToken {
//            stream.removeTrigger(sampleQueueAvailabilityToken)
//        }
//        stopRequestingOutputMediaData()
//        try? removeDecoderTriggers()
//        releaseDecoder()
//    }
//
//    override func isEnded() -> Bool { outputStreamEnded }
//
//    func createRendererError(error: Error) -> SEPlaybackError {
//        return SEPlaybackError(
//            type: .renderer(.init(
//                rendererName: name,
//                rendererIndex: 0,
//                rendererFormat: inputFormat,
//                rendererFormatSupport: nil
//            )),
//            mediaPeriodId: .init(), // TODO: mediaPeriodId
//            isRecoverable: false
//        )
//    }
//
//    func createDecoder(format: Format) throws -> D { fatalError("abstract") }
//    func renderOutputBuffer(_ buffer: D.OutputBuffer) throws -> Bool { fatalError("abstract") }
//    func onOutputStreamEnded() throws {}
//    func isReadyForMoreMediaData() -> Bool { false }
//    func requestOutputMediaDataWhenReady(_ callback: @escaping () -> Void) { fatalError("abstract") }
//    func stopRequestingOutputMediaData() {}
//    func onFirstOutputSample() {}
//
//    final func maybeInitDecoder() throws {
//        guard decoder == nil, let inputFormat else { return }
//        decoder = try createDecoder(format: inputFormat)
//        decoder?.setOutputStartTimeUs(getLastResetPosition())
//        print("MAYBE INIT DECODER")
//        try waitForDecoderOutputBuffer()
//    }
//
//    final func releaseDecoder() {
//        inputBuffer = nil
//        outputBuffer?.release(); outputBuffer = nil
//        decoderReinitializationState = .none
//        decoderReceivedBuffers = false
//        if let decoderLowWaterMarkToken {
//            try? decoder?.removeTrigger(decoderLowWaterMarkToken)
//        }
//        if let decoderHighWaterMarkToken {
//            try? decoder?.removeTrigger(decoderHighWaterMarkToken)
//        }
//        if let decoderOutputBufferAvailable {
//            try? decoder?.removeTrigger(decoderOutputBufferAvailable)
//        }
//        decoder?.onInputBufferAvailable = nil
//        decoderLowWaterMarkToken = nil
//        decoderHighWaterMarkToken = nil
//        decoderOutputBufferAvailable = nil
//        decoder?.release()
//        decoder = nil
//    }
//
//    final func flushDecoder() throws {
//        if decoderReinitializationState != .none {
//            releaseDecoder()
//            try maybeInitDecoder()
//        } else {
//            inputBuffer = nil
//            outputBuffer?.release(); outputBuffer = nil
//            decoder?.flush()
//            decoder?.setOutputStartTimeUs(getLastResetPosition())
//            decoderReceivedBuffers = false
//        }
//    }
//
//    final func onInputFormatChanged(_ newFormat: Format) throws {
//        let oldFormat = inputFormat
//        inputFormat = newFormat
//        if decoder == nil {
//            try maybeInitDecoder()
//            try installDecoderTriggers()
//            return
//        }
//
//        if !(decoder?.canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) ?? false) {
//            if decoderReceivedBuffers {
//                decoderReinitializationState = .signalEndOfStream
//            } else {
//                releaseDecoder()
//                try maybeInitDecoder()
//                try installDecoderTriggers()
//            }
//        }
//    }
//
//    final func isFormatSupportedFromAVFAsset(_ format: Format) -> Bool {
//        guard let codecs = format.codecs else {
//            return false
//        }
//
//        if let containerMimeType = format.containerMimeType {
//            let extendedMIMEType = "\(containerMimeType.rawValue); codecs=\"\(codecs)\""
//            if AVURLAsset.isPlayableExtendedMIMEType(extendedMIMEType) {
//                return true
//            }
//        }
//
//        if let sampleMimeType = format.sampleMimeType {
//            let extendedMIMEType = "\(sampleMimeType.rawValue); codecs=\"\(codecs)\""
//            if AVURLAsset.isPlayableExtendedMIMEType(extendedMIMEType) {
//                return true
//            }
//        }
//
//        let extendedMIMEType = "video/mp4; codecs=\"\(codecs)\""
//        if AVURLAsset.isPlayableExtendedMIMEType(extendedMIMEType) {
//            return true
//        }
//
//        return false
//    }
//
//    private func feedInputBuffer2() {
//        do {
//            if let currentRendererError {
//                self.currentRendererError = nil
//                throw currentRendererError
//            }
//
//            guard !outputStreamEnded else { return }
//            guard getState() != .disabled, !workingInFeedDataLoop else { return }
//            workingInFeedDataLoop = true
//            defer { workingInFeedDataLoop = false }
//
//            if inputFormat == nil {
//                flagsOnlyBuffer.clear()
//                let result = try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)
//
//                if case let .didReadFormat(format) = result {
//                    try onInputFormatChanged(format)
//                } else if case .didReadBuffer = result {
//                    assert(flagsOnlyBuffer.flags.contains(.endOfStream))
//                    inputStreamEnded = true
//                    outputStreamEnded = true
//                    return
//                } else {
//                    return
//                }
//            }
//
//            try maybeInitDecoder()
//
//            guard let decoder, let decoderHighWaterMarkToken,
//                  decoderReinitializationState != .waitEndOfStream,
//                  !inputStreamEnded else { return }
//
//            var counter = 0
//            print(""); print("--------------")
//            print("FEED INPUT BUFFER LOOP")
//            while decoder.testTrigger(decoderHighWaterMarkToken) == false {
//                if inputBuffer == nil {
//                    inputBuffer = try decoder.dequeueInputBuffer()
//                }
//                guard let inputBuffer else {
//                    if let decoderLowWaterMarkToken,
//                       decoder.testTrigger(decoderLowWaterMarkToken) == false {
//                        return
//                    }
//                    print("FINISH FEEDD INPUT BUFFER NO BUFFER, enqueued = \(counter)")
//                    print("--------------"); print("")
//                    decoder.onInputBufferAvailable = { [unowned self] in
//                        print("DECODER ON INPUT BUFFER AVAILABLE")
//                        queue.async {
//                            decoder.onInputBufferAvailable = nil
//                            feedInputBuffer2()
//                        }
//                    }
//                    return
//                }
//
//                if decoderReinitializationState == .signalEndOfStream {
//                    inputBuffer.flags.insert(.endOfStream)
//                    try decoder.queueInputBuffer(inputBuffer)
//                    self.inputBuffer = nil
//                    decoderReinitializationState = .waitEndOfStream
//                    return
//                }
//
//                switch try readSource(to: inputBuffer) {
//                case .nothingRead:
//                    if let decoderLowWaterMarkToken,
//                       decoder.testTrigger(decoderLowWaterMarkToken) == false {
//                        return
//                    }
//                    if sampleQueueAvailabilityToken == nil {
//                        if let sampleStream = getStream() {
//                            print("INSTALL SAMPLE QUEUE TRIGGER")
//                            sampleQueueAvailabilityToken = sampleStream.installTrigger(
//                                condition: .whenDataBecomesReady
//                            ) { [unowned self] token in
//                                queue.justDispatch {
////                                    print("SAMPLE QUEUEU NEW SAMPLE!!!!")
//                                    sampleStream.removeTrigger(token)
//                                    sampleQueueAvailabilityToken = nil
//                                    feedInputBuffer2()
//                                }
//                            }
//                        } else {
//                            print("DID NOT INSTALL SAMPLE QUEUE TRIGGER, NO SAMPLE STREAM")
//                        }
//                    } else {
//                        print("DID NOT INSTALL SAMPLE QUEUE TRIGGER, ALREADY INSTALLED")
//                    }
//
//                    print("FINISH FEEDD INPUT BUFFER NO DATA, enqueued = \(counter)")
//                    print("--------------"); print("")
//                    return
//                case let .didReadFormat(format):
//                    try onInputFormatChanged(format)
//                    break
//                case .didReadBuffer:
////                    print("didReadBuffer, timeUs = \(inputBuffer.timeUs), last = \(getLastResetPosition())")
//                    if inputBuffer.flags.contains(.endOfStream) {
//                        inputStreamEnded = true
//                        try decoder.queueInputBuffer(inputBuffer)
//                        self.inputBuffer = nil
//                        delegate?.rendererDidFinishReading(self)
//                        try removeDecoderTriggers()
//                        return
//                    }
//
//                    if !firstStreamSampleRead {
//                        firstStreamSampleRead = true
//                        inputBuffer.flags.insert(.firstSample)
//                    }
//
//                    inputBuffer.format = inputFormat
//                    try decoder.queueInputBuffer(inputBuffer)
//                    counter += 1
//                    decoderReceivedBuffers = true
//                    self.inputBuffer = nil
//                }
//            }
//
//            print("FINISH FEEDD INPUT BUFFER enqueued = \(counter)")
//            print("--------------"); print("")
//        } catch {
//            delegate?.onRendererError(self, error: createRendererError(error: error))
//        }
//    }
//
//    private func drainOutputBuffer2() {
//        do {
//            if let currentRendererError {
//                self.currentRendererError = nil
//                throw currentRendererError
//            }
//
//            guard !workingInOutputDataLoop else { return }
//            workingInOutputDataLoop = true
//            defer { workingInOutputDataLoop = false }
//            stopRequestingOutputMediaData()
//
//            print("📹📹📹📹📹"); print("--------------")
//            print("DRAIN RENDER LOOP")
//            var counter = 0
//            while isReadyForMoreMediaData() {
//                if outputBuffer == nil {
//                    outputBuffer = try decoder?.dequeueOutputBuffer()
//                }
//
//                guard let outputBuffer else {
//                    print("DRAIN NO BUFFER, did enqueue = \(counter)")
//                    try waitForDecoderOutputBuffer()
//                    break
//                }
//
//                if outputBuffer.sampleFlags.contains(.firstSample) {
//                    onFirstOutputSample()
//                }
//
//                if outputBuffer.sampleFlags.contains(.endOfStream) {
//                    if decoderReinitializationState == .waitEndOfStream {
//                        releaseDecoder()
//                        try maybeInitDecoder()
//                    } else {
//                        outputBuffer.release()
//                        self.outputBuffer = nil
//                        outputStreamEnded = true
//                        try onOutputStreamEnded()
//                    }
//
//                    break
//                }
//
//                let consumed = try renderOutputBuffer(outputBuffer)
//                if consumed {
//                    counter += 1
////                    print("😊 did render frame = \(outputBuffer.timeUs)")
//                    self.outputBuffer = nil
//                } else {
//                    print("DRAIN RENDER LOOP ENDED, RENDERER IS FULL, consume = \(counter)")
////                    print("😊 did NOTTTT render frame = \(outputBuffer.timeUs)")
//
//                    break
//                }
//            }
//
//            if !isReadyForMoreMediaData() {
//                requestOutputMediaDataWhenReady {
//                    print("requestOutputMediaDataWhenReady DRAIN BUFFER")
//                    self.drainOutputBuffer2()
//                }
//            }
//
//            if isReady() {
//                print("DRAIN RENDER LOOP ENDED, RENDERER IS READY, consume = \(counter)")
//                print("--------------"); print("📹📹📹📹")
//                delegate?.rendererReportsReady(self)
//            } else {
//                print("DRAIN RENDER LOOP ENDED, RENDERER IS NOTTTT!!!!! READY, consume = \(counter)")
//                print("--------------"); print("📹📹📹📹")
//                delegate?.rendererNeedsMoreData(self)
//            }
//        } catch {
//            delegate?.onRendererError(self, error: createRendererError(error: error))
//        }
//    }
//
//    private func waitForDecoderOutputBuffer() throws {
//        guard decoderOutputBufferAvailable == nil else { return }
//        stopRequestingOutputMediaData()
//        print("WAIT FOR DECODER OUPUT BUFFER, decoder is nil = \(decoder == nil)")
//        decoderOutputBufferAvailable = try decoder?.installTrigger(condition: .whenDataBecomesReady) { [unowned self] token in
//            queue.justDispatch {
//                do {
//                    print("DECODER OUTPUT BUFFER AVAILABLE")
//                    try decoder?.removeTrigger(token)
//                    decoderOutputBufferAvailable = nil
//                    drainOutputBuffer2()
//                } catch {
//                    currentRendererError = error
//                }
//            }
//        }
//    }
//
//    private func removeDecoderTriggers() throws {
//        guard let decoder,
//              let decoderLowWaterMarkToken,
//              let decoderHighWaterMarkToken else {
//            return
//        }
//
//        self.decoderLowWaterMarkToken = nil
//        self.decoderHighWaterMarkToken = nil
//        try decoder.removeTrigger(decoderLowWaterMarkToken)
//        try decoder.removeTrigger(decoderHighWaterMarkToken)
//    }
//
//    private func installDecoderTriggers() throws {
//        guard let decoder,
//              decoderLowWaterMarkToken == nil,
//              decoderHighWaterMarkToken == nil else {
//            return
//        }
//
//        let condition: (CMBufferQueue.TriggerToken) -> Void = { [unowned self] _ in
//            print("DECODER LOW WATER MARK")
//            queue.justDispatch { feedInputBuffer2() }
//        }
//
//        decoderLowWaterMarkToken = switch lowWaterMark {
//        case let .sampleCount(count):
//            try decoder.installTrigger(condition: .whenBufferCountBecomesLessThan(count), condition)
//        case let .cmTime(cmTime):
//            try decoder.installTrigger(condition: .whenDurationBecomesLessThanOrEqualTo(cmTime), condition)
//        }
//
//        decoderHighWaterMarkToken = switch hightWaterMark {
//        case let .sampleCount(count):
//            try decoder.installTrigger(condition: .whenBufferCountBecomesGreaterThan(count))
//        case let .cmTime(cmTime):
//            try decoder.installTrigger(condition: .whenDurationBecomesGreaterThanOrEqualTo(cmTime))
//        }
//    }
//}
//
//extension AVFBaseRenderer {
//    enum WaterMarkSource {
//        case sampleCount(Int)
//        case cmTime(CMTime)
//    }
//}

import AVFoundation
import Decoder

// MARK: - Protocol

public protocol AVFDecoder: Decoder where InputBuffer: DecoderInputBuffer, OutputBuffer: SimpleDecoderOutputBuffer {
    func canReuseDecoder(oldFormat: Format?, newFormat: Format) -> Bool
}

// MARK: - AVFBaseRenderer

class AVFBaseRenderer<D: AVFDecoder>: BaseSERenderer {

    // MARK: - Configuration

    var lowWaterMark: WaterMark = .sampleCount(2)
    var highWaterMark: WaterMark = .sampleCount(10)

    // MARK: - Public read-only state

    private(set) var decoder: D?
    private(set) var outputStreamEnded = false
    private(set) var inputFormat: Format?

    // MARK: - Decoder I/O buffers

    private let flagsOnlyBuffer: DecoderInputBuffer
    private var inputBuffer: D.InputBuffer?
    private var outputBuffer: D.OutputBuffer?

    // MARK: - Stream state

    private var inputStreamEnded = false
    private var firstStreamSampleRead = false
    private var decoderReceivedBuffers = false
    private var decoderReinitState: DecoderReinitState = .none

    // MARK: - Re-entrancy guards

    private var isFeedingInput = false
    private var isDrainingOutput = false

    // MARK: - Trigger tokens

    private var lowWaterMarkToken: CMBufferQueue.TriggerToken?
    private var highWaterMarkToken: CMBufferQueue.TriggerToken?
    private var outputAvailableToken: CMBufferQueue.TriggerToken?
    private var sampleQueueToken: QueueTriggerToken?

    // MARK: - Error forwarding

    /// Errors captured in trigger callbacks, re-thrown on the next loop entry.
    private var deferredError: Error?

    // MARK: - Init

    override init(queue: Queue, trackType: TrackType, clock: SEClock) {
        flagsOnlyBuffer = DecoderInputBuffer(bufferReplacementMode: .disabled)
        super.init(queue: queue, trackType: trackType, clock: clock)
    }

    // MARK: - Subclass contract

    func createDecoder(format: Format) throws -> D {
        fatalError("Subclasses must override createDecoder(format:)")
    }

    /// Return `true` if the buffer was consumed (enqueued for presentation).
    func renderOutputBuffer(_ buffer: D.OutputBuffer) throws -> Bool {
        fatalError("Subclasses must override renderOutputBuffer(_:)")
    }

    func onOutputStreamEnded() throws {}
    func isReadyForMoreMediaData() -> Bool { false }

    func requestOutputMediaDataWhenReady(_ callback: @escaping () -> Void) {
        fatalError("Subclasses must override requestOutputMediaDataWhenReady(_:)")
    }

    func stopRequestingOutputMediaData() {}
    func onFirstOutputSample() {}

    // MARK: - BaseSERenderer overrides

    override func willChangeStream() throws {
        try super.willChangeStream()
        removeSampleQueueTrigger()
    }

    override func onStreamChanged(
        formats: [Format],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        try super.onStreamChanged(
            formats: formats,
            startPosition: startPosition,
            offset: offset,
            mediaPeriodId: mediaPeriodId
        )
        firstStreamSampleRead = false
        installSampleQueueTrigger()
        scheduleFeedAndDrain()
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        inputStreamEnded = false
        outputStreamEnded = false
        firstStreamSampleRead = false
        if decoder != nil { try flushDecoder() }
        scheduleFeedAndDrain()
    }

    override func onDisabled() {
        inputFormat = nil
        removeSampleQueueTrigger()
        stopRequestingOutputMediaData()
        releaseDecoder()
    }

    override func isEnded() -> Bool { outputStreamEnded }

    // MARK: - Error factory

    func createRendererError(error: Error) -> SEPlaybackError {
        SEPlaybackError(
            type: .renderer(.init(
                rendererName: name,
                rendererIndex: 0,
                rendererFormat: inputFormat,
                rendererFormatSupport: nil
            )),
            mediaPeriodId: .init(), // TODO: carry actual mediaPeriodId
            isRecoverable: false
        )
    }

    // MARK: - Format support query

    final func isFormatSupportedFromAVFAsset(_ format: Format) -> Bool {
        guard let codecs = format.codecs else { return false }

        let mimeTypes = [
            format.containerMimeType?.rawValue,
            format.sampleMimeType?.rawValue,
            "video/mp4"   // fallback probe
        ].compactMap { $0 }

        return mimeTypes.contains { mime in
            AVURLAsset.isPlayableExtendedMIMEType("\(mime); codecs=\"\(codecs)\"")
        }
    }
}

// MARK: - Decoder lifecycle

extension AVFBaseRenderer {

    final func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }
        let newDecoder = try createDecoder(format: inputFormat)
        newDecoder.setOutputStartTime(getLastResetPosition())
        decoder = newDecoder
        try installDecoderTriggers()
        try installOutputAvailableTrigger()
        try installInputBufferAvailableCallback(decoder: newDecoder)
    }

    final func releaseDecoder() {
        inputBuffer = nil

        outputBuffer?.release()
        outputBuffer = nil

        decoderReinitState = .none
        decoderReceivedBuffers = false

        removeAllDecoderTriggers()

        decoder?.release()
        decoder = nil
    }

    final func flushDecoder() throws {
        if decoderReinitState != .none {
            // Full teardown + rebuild when a reinit was in progress.
            releaseDecoder()
            try maybeInitDecoder()
        } else {
            inputBuffer = nil
            outputBuffer?.release()
            outputBuffer = nil
            decoder?.flush()
            decoder?.setOutputStartTime(getLastResetPosition())
            decoderReceivedBuffers = false
        }
    }

    final func onInputFormatChanged(_ newFormat: Format) throws {
        let oldFormat = inputFormat
        inputFormat = newFormat

        guard let decoder else {
            try maybeInitDecoder()
            return
        }

        if decoder.canReuseDecoder(oldFormat: oldFormat, newFormat: newFormat) {
            return // reuse as-is
        }

        if decoderReceivedBuffers {
            // Can't tear down mid-stream; signal EOS to flush the decoder first.
            decoderReinitState = .signalEndOfStream
        } else {
            releaseDecoder()
            try maybeInitDecoder()
        }
    }
}

// MARK: - Scheduling helpers

private extension AVFBaseRenderer {

    /// Single entry point that kicks both the feed and drain loops.
    func scheduleFeedAndDrain() {
        feedInputBuffer()
        print("")
        print("📹 scheduleFeedAndDrain requestOutputMediaDataWhenReady")
        requestOutputMediaDataWhenReady { [weak self] in
            print("📹 requestOutputMediaDataWhenReady scheduleFeedAndDrain")
            self?.drainOutputBuffer()
        }
        print("")
    }
}

// MARK: - Feed (input) loop

private extension AVFBaseRenderer {
    func feedInputBuffer() {
        do {
            try rethrowDeferred()
            guard canEnterFeedLoop() else { return }
            isFeedingInput = true

            try ensureInputFormat()
            try maybeInitDecoder()

            guard let decoder, let highWaterMarkToken,
                  decoderReinitState != .waitEndOfStream,
                  !inputStreamEnded else { return }

            try enterFeedLoop()
        } catch {
            delegate?.onRendererError(self, error: createRendererError(error: error))
        }
    }

    func enterFeedLoop() throws {
        guard let decoder, let highWaterMarkToken else {
            isFeedingInput = false
            return
        }

        while decoder.testTrigger(highWaterMarkToken) == false {
            guard try feedOneSample(decoder: decoder) else { break }
        }
        isFeedingInput = false
    }

    func canEnterFeedLoop() -> Bool {
        !outputStreamEnded && getState() != .disabled && !isFeedingInput
    }

    /// Reads the first format from the source when `inputFormat` is still nil.
    func ensureInputFormat() throws {
        guard inputFormat == nil else { return }
        flagsOnlyBuffer.clear()
        let result = try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)

        switch result {
        case let .didReadFormat(format):
            try onInputFormatChanged(format)
        case .didReadBuffer:
            assert(flagsOnlyBuffer.flags.contains(.endOfStream))
            inputStreamEnded = true
            outputStreamEnded = true
        default:
            break
        }
    }

    /// Attempt to dequeue one input buffer, fill it from the source, and enqueue it.
    func feedOneSample(decoder: D) throws -> Bool {
        // 1. Acquire an input buffer if we don't already have one.
        if inputBuffer == nil {
            inputBuffer = try decoder.dequeueInputBuffer()
        }
        guard let buffer = inputBuffer else {
            return false
        }

        // 2. Handle pending decoder reinit (signal EOS to the old decoder).
        if decoderReinitState == .signalEndOfStream {
            buffer.flags.insert(.endOfStream)
            try decoder.queueInputBuffer(buffer)
            inputBuffer = nil
            decoderReinitState = .waitEndOfStream
            return false
        }

        // 3. Read from the sample source.
        switch try readSource(to: buffer) {
        case .nothingRead:
//            installSampleQueueTrigger()
            return false

        case let .didReadFormat(format):
            try onInputFormatChanged(format)
            return true
        case .didReadBuffer:
            if buffer.flags.contains(.endOfStream) {
                inputStreamEnded = true
                try decoder.queueInputBuffer(buffer)
                inputBuffer = nil
                delegate?.rendererDidFinishReading(self)
                try removeWaterMarkTriggers()
                return false
            }

            if !firstStreamSampleRead {
                firstStreamSampleRead = true
                buffer.flags.insert(.firstSample)
            }

            buffer.format = inputFormat
            try decoder.queueInputBuffer(buffer)
            decoderReceivedBuffers = true
            inputBuffer = nil

            return true
        }
    }

    func installInputBufferAvailableCallback(decoder: D) {
        decoder.onInputBufferAvailable = { [weak self] in
            self?.checkForInputWaterMarkLevel()
        }
    }
}

// MARK: - Drain (output) loop

private extension AVFBaseRenderer {
    func drainOutputBuffer() {
        do {
            try rethrowDeferred()
            guard !isDrainingOutput else { return }
            isDrainingOutput = true
            defer {
                isDrainingOutput = false
                reportReadinessToDelegate()
            }
            stopRequestingOutputMediaData()

            var counter = 0
            print()
            print("------------- time = \(getClock().milliseconds)")
            print("📹📹📹📹📹📹")
//            while isReadyForMoreMediaData() {
//                if outputBuffer == nil {
//                    outputBuffer = try decoder?.dequeueOutputBuffer()
//                }
//                guard let buffer = outputBuffer else {
//                    try installOutputAvailableTrigger()
//                    print("📹📹📹📹📹📹")
//                    print("No available buffer, counter = \(counter)")
//                    print("-------------")
//                    print()
//                    return
//                }
//
//                if try handleSpecialOutputFlags(buffer) { break }
//
//                let consumed = try renderOutputBuffer(buffer)
//                if consumed {
//                    counter += 1
//                    outputBuffer = nil
//                } else {
//                    break // back-pressure from the downstream renderer
//                }
//            }
            while true {
                if isReadyForMoreMediaData() {
                    if outputBuffer == nil {
                        outputBuffer = try decoder?.dequeueOutputBuffer()
                    }
                    guard let buffer = outputBuffer else {
                        try installOutputAvailableTrigger()
                        print("📹📹📹📹📹📹")
                        print("No available buffer, isReady = \(isReadyForMoreMediaData()), counter = \(counter)")
                        print("-------------")
                        print()
                        return
                    }

                    if try handleSpecialOutputFlags(buffer) { break }

                    let consumed = try renderOutputBuffer(buffer)
                    if consumed {
                        counter += 1
                        outputBuffer = nil
                    } else {
                        break // back-pressure from the downstream renderer
                    }
                } else {
                    print("STOPPED BEING READY FOR MORE MEDIA DATA, counter = \(counter)")
                    break
                }
            }

            scheduleNextDrain(counter)
        } catch {
            delegate?.onRendererError(self, error: createRendererError(error: error))
        }
    }

    /// Returns `true` if the buffer was a special (first/EOS) buffer that terminates the loop.
    func handleSpecialOutputFlags(_ buffer: D.OutputBuffer) throws -> Bool {
        if buffer.sampleFlags.contains(.firstSample) {
            onFirstOutputSample()
        }

        guard buffer.sampleFlags.contains(.endOfStream) else { return false }

        if decoderReinitState == .waitEndOfStream {
            // Old decoder drained — rebuild for the new format.
            releaseDecoder()
            try maybeInitDecoder()
        } else {
            buffer.release()
            outputBuffer = nil
            outputStreamEnded = true
            try onOutputStreamEnded()
        }
        return true
    }

    func scheduleNextDrain(_ counter: Int) {
//        guard !isReadyForMoreMediaData() else { return }
        print("📹 2 scheduleNextDrain requestOutputMediaDataWhenReady")
        requestOutputMediaDataWhenReady { [weak self] in
            print("📹 requestOutputMediaDataWhenReady scheduleNextDrain 2")
            self?.drainOutputBuffer()
        }
        print("📹📹📹📹📹📹 counter = \(counter)")
        print("-------------")
        print()
    }

    func reportReadinessToDelegate() {
        if isReady() {
            delegate?.rendererReportsReady(self)
        } else {
            delegate?.rendererNeedsMoreData(self)
        }
    }
}

// MARK: - Trigger management

private extension AVFBaseRenderer {
    func installDecoderTriggers() throws {
        guard let decoder,
              lowWaterMarkToken == nil,
              highWaterMarkToken == nil else { return }

        let onLowWater: (CMBufferQueue.TriggerToken) -> Void = { [weak self] _ in
            guard let self else { return }
            queue.justDispatch { self.feedInputBuffer() }
        }

        lowWaterMarkToken = switch lowWaterMark {
        case let .sampleCount(n):
            try decoder.installTrigger(condition: .whenBufferCountBecomesLessThan(n), onLowWater)
        case let .cmTime(t):
            try decoder.installTrigger(condition: .whenDurationBecomesLessThanOrEqualTo(t), onLowWater)
        }

        highWaterMarkToken = switch highWaterMark {
        case let .sampleCount(n):
            try decoder.installTrigger(condition: .whenBufferCountBecomesGreaterThan(n))
        case let .cmTime(t):
            try decoder.installTrigger(condition: .whenDurationBecomesGreaterThanOrEqualTo(t))
        }
    }

    func installOutputAvailableTrigger() throws {
        guard outputAvailableToken == nil, let decoder else { return }
        stopRequestingOutputMediaData()

        outputAvailableToken = try decoder.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] token in
            guard let self else { return }
            queue.justDispatchWithQoS(qos: .userInteractive) {
                print(); print(); print()
                print("📹📹📹 NEW DECODER OUTPUT BUFFER IS AVAILABLE 📹📹📹")
                print(); print(); print()
                do {
                    try self.decoder?.removeTrigger(token)
                    self.outputAvailableToken = nil
                    self.drainOutputBuffer()
                } catch {
                    self.deferredError = error
                }
            }
        }
    }

    func installSampleQueueTrigger() {
        guard sampleQueueToken == nil, let stream = getStream() else { return }

        sampleQueueToken = stream.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] token in
            self?.checkForInputWaterMarkLevel()
        }
    }

    private func checkForInputWaterMarkLevel() {
        queue.justDispatchWithQoS(qos: .utility) {
            if let decoder = self.decoder, let lowWaterMarkToken = self.lowWaterMarkToken,
                decoder.testTrigger(lowWaterMarkToken) {
                self.feedInputBuffer()
            }
        }
    }

    func removeSampleQueueTrigger() {
        guard let token = sampleQueueToken, let stream = getStream() else { return }
        stream.removeTrigger(token)
        sampleQueueToken = nil
    }

    func removeWaterMarkTriggers() throws {
        // Capture and nil before calling removeTrigger to avoid
        // re-entrancy issues if removal itself triggers a callback.
        let low = lowWaterMarkToken
        let high = highWaterMarkToken
        lowWaterMarkToken = nil
        highWaterMarkToken = nil

        if let low  { try decoder?.removeTrigger(low) }
        if let high { try decoder?.removeTrigger(high) }
    }

    func removeAllDecoderTriggers() {
        // Best-effort removal — decoder may already be nil.
        let tokens: [CMBufferQueue.TriggerToken?] = [
            lowWaterMarkToken, highWaterMarkToken, outputAvailableToken
        ]
        lowWaterMarkToken = nil
        highWaterMarkToken = nil
        outputAvailableToken = nil
        decoder?.onInputBufferAvailable = nil

        for token in tokens.compactMap({ $0 }) {
            try? decoder?.removeTrigger(token)
        }
    }
}

private extension AVFBaseRenderer {
    func rethrowDeferred() throws {
        if let error = deferredError {
            deferredError = nil
            throw error
        }
    }
}

extension AVFBaseRenderer {
    enum WaterMark {
        case sampleCount(Int)
        case cmTime(CMTime)
    }

    private enum DecoderReinitState {
        case none
        case signalEndOfStream
        case waitEndOfStream
    }
}
