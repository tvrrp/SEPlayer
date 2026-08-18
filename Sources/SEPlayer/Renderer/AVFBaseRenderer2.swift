//
//  AVFBaseRenderer2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import AVFoundation
import SEPlayerCommon

class AVFBaseRenderer2: BaseSERenderer {
    var outputMode: OutputMode = .passthrough {
        didSet { onOutputModeChanged() }
    }

    private let stallTimer: DispatchSourceTimer
    private let rendererFinishedTimer: DispatchSourceTimer

    private var outputAvailableToken: CMBufferQueue.TriggerToken?
    private var sampleQueueToken: QueueTriggerToken?
    private var inputBuffer: CMSampleBuffer?
    private var wasReady = false
    private var lastEnqueuedSample: CMTimeRange = .invalid
    private var controlTimebase: CMTimebase?

    private var currentError: SEPlaybackError?

    private var pendingOutputMode: OutputMode?
    private var rendererAtEndOfStream = false
    private var isRenderingEnded = false

    override init(queue: any Queue, trackType: TrackType, clock: any SEClock) {
        stallTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        rendererFinishedTimer = DispatchSource.makeTimerSource(queue: queue.queue)

        super.init(queue: queue, trackType: trackType, clock: clock)
//        handler.callback = self

        stallTimer.setEventHandler { [weak self] in
            guard let self else { return }

//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED TIMER 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED TIMER 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED TIMER 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED TIMER 🌈🌈🌈🌈🌈🌈🌈🌈🌈")

            if !isReady() && wasReady {
                wasReady = false
                delegate?.rendererPipelineStalled(self)
            }
        }

        rendererFinishedTimer.setEventHandler{ [weak self] in
            guard let self else { return }

//            print("🌈 DID FINISH RENDERING")
            isRenderingEnded = true
            delegate?.rendererDidFinishRendering(self)
        }

        stallTimer.activate()
        rendererFinishedTimer.activate()
    }

    deinit {
        stallTimer.cancel()
        rendererFinishedTimer.cancel()
    }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        guard let codecs = format.codecs else { return .create(formatSupport: .unsupportedType) }

        let mimeTypes = [
            format.containerMimeType?.rawValue,
            format.sampleMimeType?.rawValue,
            "video/mp4"   // fallback probe
        ].compactMap { $0 }

        let result = mimeTypes.contains { mime in
            AVURLAsset.isPlayableExtendedMIMEType("\(mime); codecs=\"\(codecs)\"")
        }

        return result ? .create(formatSupport: .handled) : .create(formatSupport: .unsupportedType)
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setControlTimebase(timebase) = message {
            controlTimebase = timebase
            try timebase?.addTimer(stallTimer)
            try timebase?.addTimer(rendererFinishedTimer)
        }

        try super.handleMessage(message)
    }

    override func isEnded() -> Bool {
        return isRenderingEnded
    }

    override func willChangeStream(oldStream: (any SampleStream)?, newStream: inout any SampleStream) throws {
        if let oldStream, let sampleQueueToken {
            self.sampleQueueToken = nil
            oldStream.removeTrigger(sampleQueueToken)
        }
    }

    override func onStreamChanged(
        formats: [Format],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        isRenderingEnded = false
        rendererAtEndOfStream = false

        if outputMode == .passthrough {
            try installInputQueueTrigger()
        } else {
            try installInputQueueTrigger()
            try installOutputQueueTriggers()
        }
    }

    override func setStreamFinal() {
        super.setStreamFinal()

        if !rendererAtEndOfStream {
            readInputStream()
        }
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)
        try controlTimebase?.setTimerNextFireTime(rendererFinishedTimer, fireTime: .invalid)

        currentError = nil
        wasReady = false
        isRenderingEnded = false
        rendererAtEndOfStream = false
    }

    override func onStopped() {
        try? controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)
        try? controlTimebase?.setTimerNextFireTime(rendererFinishedTimer, fireTime: .invalid)
    }

    override func onDisabled() {
        currentError = nil

        stopRequestingOutputMediaData()
        if let sampleQueueToken {
            getStream()?.removeTrigger(sampleQueueToken)
            self.sampleQueueToken = nil
        }

        if let outputAvailableToken {
            try? getDecodeBufferQueue()?.removeTrigger(outputAvailableToken)
            self.outputAvailableToken = nil
        }
    }

//    override func onPositionReset(position: CMTime, joining: Bool) throws {
//        try super.onPositionReset(position: position, joining: joining)
//        print("ℹ️ onPositionReset, position = \(position.seconds)")
//    }

    final func changeOutputMode(to outputMode: OutputMode) {
        guard self.outputMode != outputMode else { return }
        pendingOutputMode = outputMode
    }

    func onOutputModeChanged() {}

    func feedInputBuffer(readStream: (ReadFlags) throws -> SampleStreamReadResult) throws -> Bool { fatalError("To ovveride") }
    func getDecodeBufferQueue() throws -> TypedCMBufferQueue<CMSampleBuffer>? { fatalError("To ovveride") }
    func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool { fatalError("To ovveride") }
    func onInputFormatChanged(_ format: Format) throws { fatalError("To ovveride") }
    func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) { fatalError("To ovveride") }
    func stopRequestingOutputMediaData() { fatalError("To ovveride") }
    func createPlaybackError(_ error: Error) -> SEPlaybackError { fatalError("To ovveride") }

    final func rendererDidChangeIsReady() {
        if isReady() && !wasReady {
            delegate?.rendererFinishedPreroll(self)
        } else if !isReady() && wasReady {
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED ON CHANGE 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED ON CHANGE 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED ON CHANGE 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//            print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER STALLED ON CHANGE 🌈🌈🌈🌈🌈🌈🌈🌈🌈")

            delegate?.rendererPipelineStalled(self)
        }
    }

    final func readInputStream() {
        assert(queue.isCurrent())
        guard currentError == nil else { return }

        if let sampleQueueToken {
            getStream()?.removeTrigger(sampleQueueToken)
            self.sampleQueueToken = nil
        }

        do {
            while try pumpReadStream() {}
        } catch {
            let currentError = createPlaybackError(error)
            self.currentError = currentError
            delegate?.onRendererError(self, error: createPlaybackError(error))
        }
    }

    private func pumpReadStream() throws -> Bool {
        if let pendingOutputMode {
            if case let .didReadBuffer(buffer) = try readSource(readFlags: .peek) {
                if buffer.flags.contains(.keyframe) {
                    switch pendingOutputMode {
                    case .decode:
                        outputMode = pendingOutputMode
                        self.pendingOutputMode = nil
                        onOutputModeChanged()
                        queue.justDispatch { self.feedOutputStream() }

                        try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)

                        return true
                    case .passthrough:
                        return false
                    }
                }
            }
        }

        if outputMode == .decode {
            return try feedInputBuffer { flags in
                let result = try readSource(readFlags: flags)
                if case .nothingRead = result {
                    try installInputQueueTrigger()
                }

                return result
            }
        }

        switch try readSource() {
        case .nothingRead:
            try installInputQueueTrigger()

            if lastEnqueuedSample.isValid {
                try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: lastEnqueuedSample.end)
            }

            return false
        case let .didReadFormat(format):
            try onInputFormatChanged(format)
            return true
        case let .didReadBuffer(buffer):
            try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)

            if buffer.flags.contains(.endOfStream), !rendererAtEndOfStream {
                rendererAtEndOfStream = true
                try controlTimebase?.setTimerNextFireTime(rendererFinishedTimer, fireTime: lastEnqueuedSample.end)
                return false
            }

            for singleSample in try buffer.singleSampleBuffers() {
                if singleSample.outputPresentationTimeStamp < getLastResetPosition() {
                    singleSample.sampleAttachments[0][.doNotDisplay] = true
                }
            }

            let isReadyForMoreMediaData = try feedOutputBuffer(buffer)
            lastEnqueuedSample = .init(start: buffer.outputPresentationTimeStamp, duration: buffer.duration)

            if !isReadyForMoreMediaData {
                requestOutputMediaDataWhenReady { [unowned self] in
                    stopRequestingOutputMediaData()
                    readInputStream()
                }

                if isReady() && !wasReady {
                    wasReady = true
                    delegate?.rendererFinishedPreroll(self)
                }
            }

            return isReadyForMoreMediaData
        }
    }

    private func feedOutputStream() {
        assert(queue.isCurrent())
        guard currentError == nil else { return }

        do {
            stopRequestingOutputMediaData()
            if let token = outputAvailableToken {
                try getDecodeBufferQueue()?.removeTrigger(token)
                outputAvailableToken = nil
            }

            while try pumpOutputStream() {}
//            print("🏈🏈🏈🏈🏈 ============== END REQUEST IS READY = \(isReady()) ============== 🏈🏈🏈🏈🏈")
        } catch {
            let currentError = createPlaybackError(error)
            self.currentError = currentError
            delegate?.onRendererError(self, error: createPlaybackError(error))
        }
    }

    private func pumpOutputStream() throws -> Bool {
        guard let decodeBufferQueue = try getDecodeBufferQueue() else { return false }

        guard let buffer = decodeBufferQueue.dequeue() else {
            if let pendingOutputMode, pendingOutputMode == .passthrough {
                outputMode = pendingOutputMode
                self.pendingOutputMode = nil
                onOutputModeChanged()
                queue.justDispatch { self.readInputStream() }
                try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)
                return false
            }

            try installOutputQueueTriggers()

            if lastEnqueuedSample.isValid {
                try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: lastEnqueuedSample.end)
            }

            return false
        }

        try controlTimebase?.setTimerNextFireTime(stallTimer, fireTime: .invalid)
        let isReadyForMoreMediaData = try feedOutputBuffer(buffer)
        lastEnqueuedSample = .init(start: buffer.outputPresentationTimeStamp, duration: buffer.duration)

        if !isReadyForMoreMediaData {
            if outputMode == .decode {
//                print()
            }

            requestOutputMediaDataWhenReady { [unowned self] in
//                print("🏈🏈🏈🏈🏈 ============== REQUEST ============== 🏈🏈🏈🏈🏈")
                stopRequestingOutputMediaData()
                feedOutputStream()
            }

            if isReady() && !wasReady {
                wasReady = true
                delegate?.rendererFinishedPreroll(self)

//                print("🏈🏈🏈🏈🏈 ============== REQUEST FINISHED PREROLL ============== 🏈🏈🏈🏈🏈")
            }
        }

        return isReadyForMoreMediaData
    }

    private func installInputQueueTrigger() throws {
        guard sampleQueueToken == nil, let stream = getStream() else { return }

        sampleQueueToken = stream.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] token in
            guard let self else { return }

            queue.justDispatch { self.readInputStream() }
        }
    }

    private func installOutputQueueTriggers() throws {
        guard outputAvailableToken == nil else {
            return
        }

        outputAvailableToken = try getDecodeBufferQueue()?.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] token in
            guard let self else { return }

            queue.justDispatch { self.feedOutputStream() }
        }
    }
}

extension AVFBaseRenderer2 {
    enum OutputMode {
        case passthrough
        case decode
    }
}
