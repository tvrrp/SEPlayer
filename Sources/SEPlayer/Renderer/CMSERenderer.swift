//
//  CMSERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.04.2025.
//
//
//import CoreMedia
//
//protocol RendererBufferProvider: AnyObject {
//    func dequeueBuffer() -> CMBlockBuffer?
//}
//
//class CMSERenderer: BaseSERenderer2 {
//    var didInitCodec = false
//
//    private let decompressedSamplesQueue: TypedCMBufferQueue<CMSampleBuffer>
//
//    private let bufferProvider: RendererBufferProvider
//    private let noDataBuffer: DecoderInputBuffer
//    private let buffer: DecoderInputBuffer
//
//    private var inputSample: CMSampleBuffer?
//    private var outputSample: CMSampleBuffer?
//    private var isDecodeOnlyOutputSample: Bool = false
//    private var isLastOutputSample: Bool = false
//    private var _framedInQueue = 0
//
//    private var largestQueuedPTS: Int64?
//
//    private var outputStreamInfo: OutputStreamInfo = .unset
//    private var pendingOutputStreamChanges: [OutputStreamInfo] = []
//
//    private var lastProcessedOutputBufferTime: Int64?
//
//    private var largestQueuedPresentationTime: Int64 = .zero
//    private var lastSampleInStreamPTS: Int64 = .min
//
//    private var inputStreamEnded = false
//    private var outputStreamEnded = false
//    private var pendingOutputEndOfStream = false
//
//    private var waitingForFirstSampleInFormat = true
//
//    private var pendingPlaybackError: Error?
//    private var inputFormat: CMFormatDescription?
//
//    private var bypassEnabled = false
//    private var bypassDrainAndReinitialize = false
//
//    private var codecDrainState: CodecDrainState = .none
//
//    private var codecReceivedBuffers = false
//
//    init(queue: Queue, trackType: TrackType, clock: CMClock, bufferProvider: RendererBufferProvider) throws {
//        noDataBuffer = try DecoderInputBuffer()
//        buffer = try DecoderInputBuffer()
//        decompressedSamplesQueue = try TypedCMBufferQueue<CMSampleBuffer>(
//            capacity: 100,
//            handlers: .outputPTSSortedSampleBuffers
//        )
//        self.bufferProvider = bufferProvider
//
//        try super.init(queue: queue, trackType: trackType, clock: clock)
//    }
//
//    final func maybeInitCodecOrBypass() throws {
//        guard !didInitCodec, !bypassEnabled, let inputFormat else { return }
//
//        if shouldUseBypass(format: inputFormat) {
//            initBypass(format: inputFormat)
//            return
//        }
//
//        try initCodec(format: inputFormat)
//    }
//
//    // Offload rendering to other parts of the pipeline (such as AudioQueue prime)
//    private func initBypass(format: CMFormatDescription) {
//        disableBypass()
//        bypassEnabled = true
//    }
//
//    func initCodec(format: CMFormatDescription) throws {}
//
//    final func setPendingPlaybackError(_ error: Error) {
//        self.pendingPlaybackError = error
//    }
//
//    override func onStreamChanged(formats: [CMFormatDescription], startPosition: Int64, offset: Int64, mediaPeriodId: MediaPeriodId) throws {
//        if outputStreamInfo.streamOffset == nil {
//            setOutputStreamInfo(new: .init(
//                previousStreamLastBufferTime: nil,
//                startPosition: startPosition,
//                streamOffset: offset
//            ))
//        } else if pendingOutputStreamChanges.isEmpty
//                 && (largestQueuedPTS == nil
//                     || (lastProcessedOutputBufferTime != nil && lastProcessedOutputBufferTime! >= largestQueuedPresentationTime)) {
//            setOutputStreamInfo(new: .init(
//                previousStreamLastBufferTime: nil,
//                startPosition: startPosition,
//                streamOffset: offset
//            ))
//            if outputStreamInfo.streamOffset != nil {
//                onProcessedStreamChange()
//            }
//        } else {
//            pendingOutputStreamChanges.append(.init(
//                previousStreamLastBufferTime: largestQueuedPresentationTime,
//                startPosition: startPosition,
//                streamOffset: offset
//            ))
//        }
//    }
//
//    override func onPositionReset(position: Int64, joining: Bool) throws {
//        inputStreamEnded = false
//        outputStreamEnded = false
//        pendingOutputEndOfStream = false
//        try flushOrReleaseCodec()
//        if outputStreamInfo.formatQueue.size > 0 {
//            waitingForFirstSampleInFormat = true
//        }
//        outputStreamInfo.formatQueue.clear()
//        pendingOutputStreamChanges.removeAll()
//    }
//
//    override func setPlaybackSpeed(current: Float, target: Float) throws {
//        
//    }
//
//    override func onDisabled() {
//        inputFormat = nil
//        setOutputStreamInfo(new: .unset)
//        pendingOutputStreamChanges.removeAll()
//        _ = try? flushOrReleaseCodec()
//    }
//
//    override func onReset() {
//        // TODO: 
//    }
//
//    private func disableBypass() {
//        bypassEnabled = false
//    }
//
//    override final func render(position: Int64, elapsedRealtime: Int64) throws {
//        if pendingOutputEndOfStream {
//            pendingOutputEndOfStream = false
//            try processEndOfStream()
//        }
//
//        if let pendingPlaybackError {
//            self.pendingPlaybackError = nil
//            throw pendingPlaybackError
//        }
//
//        do {
//            if outputStreamEnded {
//                try renderToEndOfStream()
//                return
//            }
//
//            if inputFormat == nil, try !readSourceOmmitingSampleData(readFlags: .requireFormat) {
//                return
//            }
//            try maybeInitCodecOrBypass()
//
//            if bypassEnabled {
//                throw CancellationError()
//            } else if didInitCodec {
//                let startTime = getClock().microseconds
//                while try drainOutputQueue(position: position, elapsedRealtime: elapsedRealtime),
//                      shouldContinueRendering(from: startTime) {}
//                while try feedInputBuffer(), shouldContinueRendering(from: startTime) {}
//            } else {
//                try readSourceOmmitingSampleData(readFlags: .peek)
//            }
//        } catch {
//            throw error
//        }
//    }
//
//    func resetStateForFlush() {
//        resetInputBuffer()
//        resetOutputBuffer()
//        isDecodeOnlyOutputSample = false
//        isLastOutputSample = false
//        largestQueuedPTS = nil
//    }
//
//    private func readSourceOmmitingSampleData(readFlags: ReadFlags = .init()) throws -> Bool {
//        let result = try readSource(to: noDataBuffer, readFlags: readFlags)
//
//        if case let .didReadFormat(format) = result {
//            try onInputFormatChanged(format: format)
//            return true
//        } else if case .didReadBuffer = result, noDataBuffer.flags.contains(.endOfStream) {
//            inputStreamEnded = true
//            try processEndOfStream()
//        }
//
//        return false
//    }
//
//    private func drainOutputQueue(position: Int64, elapsedRealtime: Int64) throws -> Bool {
//        let sampleBuffer = outputSample ?? decompressedSamplesQueue.dequeue()
//        guard let sampleBuffer else { return false }
//
//        isDecodeOnlyOutputSample = sampleBuffer.presentationTimeStamp.microseconds < getLastResetPosition()
//        isLastOutputSample = lastSampleInStreamPTS > 0 && lastSampleInStreamPTS <= sampleBuffer.presentationTimeStamp.microseconds
//        // TODO: update output format for time
//
//        let processedOutputSample = processOutputSample(
//            position: position,
//            elapsedRealtime: elapsedRealtime,
//            presentationTime: sampleBuffer.presentationTimeStamp.microseconds,
//            sample: sampleBuffer,
//            decodeOnly: isDecodeOnlyOutputSample,
//            isLastSample: isLastOutputSample
//        )
//
//        if processedOutputSample {
//            // TODO: onProcessedOutputBuffer
//            let endOfStream = false // TODO: handle end of stream
//            resetOutputBuffer()
//            if !endOfStream { return true }
//            try processEndOfStream()
//        }
//
//        return false
//    }
//
//    private func feedInputBuffer() throws -> Bool {
//        guard didInitCodec, codecDrainState != .waitEndOfStream, !inputStreamEnded else { return false }
//
//        if !buffer.isReady {
//            if let blockBuffer = bufferProvider.dequeueBuffer() {
//                buffer.enqueue(buffer: blockBuffer)
//            } else {
//                return false
//            }
//        }
//
//        if codecDrainState == .endOfStream {
//            resetInputBuffer()
//            codecDrainState = .waitEndOfStream
//            return false
//        }
//
//        let result: SampleStreamReadResult2
//        do {
//            result = try readSource(to: buffer)
//        } catch {
//            if let error = error as? DecoderInputBuffer.BufferErrors {
//                try readSourceOmmitingSampleData()
////                flu
//                return true
//            } else {
//                throw error
//            }
//        }
//
//        if result == .nothingRead {
//            if didReadStreamToEnd() {
//                lastSampleInStreamPTS = largestQueuedPresentationTime
//            }
//            return false
//        } else if case let .didReadFormat(format) = result {
//            try onInputFormatChanged(format: format)
//            return true
//        }
//
//        if buffer.flags.contains(.endOfStream) {
//            lastSampleInStreamPTS = largestQueuedPresentationTime
//            inputStreamEnded = true
//            if !codecReceivedBuffers {
//                try processEndOfStream()
//                return false
//            }
//            resetInputBuffer()
//            return false
//        }
//
//        if shouldDiscardDecoderInputBuffer(buffer) {
//            return true
//        }
//
//        let presentationTime = buffer.time
//        if waitingForFirstSampleInFormat {
//            if let inputFormat {
//                if !pendingOutputStreamChanges.isEmpty {
//                    pendingOutputStreamChanges
//                        .last?
//                        .formatQueue
//                        .add(timestamp: presentationTime, value: inputFormat)
//                } else {
//                    outputStreamInfo.formatQueue
//                        .add(timestamp: presentationTime, value: inputFormat)
//                }
//            } else {
//                fatalError() // TODO: throw error
//            }
//        }
//        largestQueuedPresentationTime = presentationTime
//        if didReadStreamToEnd() || buffer.flags.contains(.lastSample) {
//            lastSampleInStreamPTS = presentationTime
//        }
//        try queueInputBuffer(buffer: buffer)
//        resetInputBuffer()
//        codecReceivedBuffers = true
//
//        return true
//    }
//
//    func queueInputBuffer(buffer: DecoderInputBuffer) throws {}
//
//    func onProcessedStreamChange() {}
//
//    private func setOutputStreamInfo(new outputStreamInfo: OutputStreamInfo) {
//        self.outputStreamInfo = outputStreamInfo
////        if let streamOffset = outputStreamInfo.streamOffset {
////            
////        }
//    }
//
//    func onOutputStreamOffsetChanged(outputStreamOffset: Int64) {}
//
//    func queueInputSample(sampleBuffer: CMSampleBuffer) -> Bool {
//        return false
//    }
//
//    func shouldDiscardDecoderInputBuffer(_ buffer: DecoderInputBuffer) -> Bool {
//        return false
//    }
//
//    func processOutputSample(
//        position: Int64,
//        elapsedRealtime: Int64,
//        presentationTime: Int64,
//        sample: CMSampleBuffer,
//        decodeOnly: Bool,
//        isLastSample: Bool
//    ) -> Bool {
//        return false
//    }
//
//    @discardableResult
//    final func flushOrReinitializeCodec() throws -> Bool {
//        let released = try flushOrReleaseCodec()
//        if released {
//            
//        }
//        return released
//    }
//
//    @discardableResult
//    func flushOrReleaseCodec() throws -> Bool {
//        return true
//    }
//
//    func renderToEndOfStream() throws {}
//
//    private func processEndOfStream() throws {
//        outputStreamEnded = true
//        try renderToEndOfStream()
//    }
//
//    func onInputFormatChanged(format: CMFormatDescription) throws {
//        waitingForFirstSampleInFormat = true
//        inputFormat = format
//
//        if bypassEnabled {
//            bypassDrainAndReinitialize = true
//            return
//        }
//
//        if !didInitCodec {
//            try maybeInitCodecOrBypass()
//            return
//        }
//
//        // Changing format not supported
//        throw CancellationError()
//    }
//
//    func shouldUseBypass(format: CMFormatDescription) -> Bool {
//        return false
//    }
//}
//
//private extension CMSERenderer {
//    func resetInputBuffer() {
//        inputSample = nil
//        buffer.reset()
//    }
//
//    func resetOutputBuffer() {
//        outputSample = nil
//    }
//
//    private func shouldContinueRendering(from startTime: Int64) -> Bool {
//        return getClock().microseconds - startTime < .renderLimit
//    }
//}
//
//private extension CMSERenderer {
//    struct OutputStreamInfo {
//        let previousStreamLastBufferTime: Int64?
//        let startPosition: Int64?
//        let streamOffset: Int64?
//        let formatQueue: TimedValueQueue<CMFormatDescription>
//
//        init(previousStreamLastBufferTime: Int64?, startPosition: Int64?, streamOffset: Int64?) {
//            self.previousStreamLastBufferTime = previousStreamLastBufferTime
//            self.startPosition = startPosition
//            self.streamOffset = streamOffset
//            self.formatQueue = TimedValueQueue<CMFormatDescription>()
//        }
//
//        static let unset = OutputStreamInfo(
//            previousStreamLastBufferTime: nil,
//            startPosition: nil,
//            streamOffset: nil
//        )
//    }
//}
//
//private extension Int64 {
//    static let renderLimit: Int64 = 1000
//}
//
//private extension CMSERenderer {
//    enum CodecDrainState {
//        case none
//        case endOfStream
//        case waitEndOfStream
//    }
//}
