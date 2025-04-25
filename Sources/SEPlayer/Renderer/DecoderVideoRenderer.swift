//
//  DecoderVideoRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.04.2025.
//

import CoreMedia

class DecoderVideoRenderer<Decoder: SEDecoder>: BaseSERenderer2 {
    var decoder: Decoder?

    private let formatQueue: TimedValueQueue<CMFormatDescription>
    private let flagsOnlyBuffer: DecoderInputBuffer

    private var inputFormat: CMFormatDescription?

    private var inputIndex: Int?
    private var inputBuffer: DecoderInputBuffer
    private var outputBuffer: Decoder.OutputBuffer?

    private var decoderReinitializationState: ReinitializationState = .none
    private var decoderReceivedBuffers: Bool = false

    private var initialPosition: Int64?
    private var joiningDeadline: Int64?
    private var waitingForFirstSampleInFormat = false

    private var inputStreamEnded = false
    private var outputStreamEnded = false

    private var buffersInCodecCount = 0
    private var lastRenderTime: Int64 = 0

    init(queue: Queue, clock: CMClock) {
        formatQueue = TimedValueQueue<CMFormatDescription>()
        flagsOnlyBuffer = DecoderInputBuffer()
        inputBuffer = DecoderInputBuffer()
        super.init(queue: queue, trackType: .video, clock: clock)
    }

    override func render(position: Int64, elapsedRealtime: Int64) throws {
        guard !outputStreamEnded else { return }

        if inputFormat == nil {
            let result = try readSource(to: flagsOnlyBuffer, readFlags: .requireFormat)
            switch result {
            case let .didReadFormat(format):
                try onInputFormatChanged(format: format)
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

        try maybeInitDecoder()

        if decoder != nil {
            while try drainOutputBuffer(position: position, elapsedRealtime: elapsedRealtime) {}
            while try feedInputBuffer() {}
        }
    }

    override func isEnded() -> Bool { outputStreamEnded }

    override func isReady() -> Bool {
        if inputFormat != nil, (isSourceReady() || outputBuffer != nil) {
            joiningDeadline = nil
            return true
        } else if let joiningDeadline, getClock().microseconds > joiningDeadline {
            return true
        } else if joiningDeadline == nil {
            return false
        } else {
            joiningDeadline = nil
            return false
        }
    }

    override func onPositionReset(position: Int64, joining: Bool) throws {
        inputStreamEnded = false
        outputStreamEnded = false
        initialPosition = nil
        if decoder != nil {
            try flushDecoder()
        }
        if joining {
            
//            videoFrameReleaseControl.join // TODO: join
        } else {
            joiningDeadline = nil
        }
        formatQueue.clear()
    }

    override func onStarted() throws {
        lastRenderTime = getClock().microseconds
    }

    override func onStopped() {
        joiningDeadline = nil
    }

    override func onDisabled() {
        inputFormat = nil
        releaseDecoder()
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

    func onQueueInputBuffer(_ buffer: DecoderInputBuffer) {}
    func onProcessedOutputBuffer(presentationTime: Int64) { buffersInCodecCount -= 1 }

    func maybeDropBuffersToKeyframe(position: Int64) throws -> Bool {
        let droppedSourceBufferCount = skipSource(position: position)
        guard droppedSourceBufferCount > 0 else { return false }

        try flushDecoder()
        return true
    }

    func createDecoder(format: CMFormatDescription) throws -> Decoder { fatalError() }

    func maybeInitDecoder() throws {
        guard decoder == nil, let inputFormat else { return }
        let decoder = try createDecoder(format: inputFormat)
        self.decoder = decoder
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
                try decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
                resetInputBuffer()
                return false
            }
            if waitingForFirstSampleInFormat, let inputFormat {
                formatQueue.add(timestamp: inputBuffer.time, value: inputFormat)
                waitingForFirstSampleInFormat = false
            }
            try decoder.queueInputBuffer(for: inputIndex, inputBuffer: inputBuffer)
            buffersInCodecCount += 1
            decoderReceivedBuffers = true
            resetInputBuffer()
            return true
        case .nothingRead:
            return false
        }
    }

    private func drainOutputBuffer(position: Int64, elapsedRealtime: Int64) throws -> Bool {
        outputBuffer = self.outputBuffer ?? decoder?.dequeueOutputBuffer()
        guard let outputBuffer else { return false }

        if outputBuffer.sampleFlags.contains(.endOfStream) {
            if decoderReinitializationState == .waitEndOfStream {
                releaseDecoder()
                try maybeInitDecoder()
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

    func processOutputBuffer(buffer: Decoder.OutputBuffer, position: Int64, elapsedRealtime: Int64) -> Bool {
        return false
    }

    func canReuseDecoder(oldFormat: CMFormatDescription?, newFormat: CMFormatDescription) -> Bool {
        return false
    }
}

private extension DecoderVideoRenderer {
    func resetInputBuffer() {
        inputIndex = nil
        inputBuffer.reset()
    }
}

private extension DecoderVideoRenderer {
    enum ReinitializationState {
        case none
        case signalEndOfStream
        case waitEndOfStream
    }
}
