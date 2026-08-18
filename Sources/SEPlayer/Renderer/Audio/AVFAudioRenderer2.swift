//
//  AVFAudioRenderer2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import AVFoundation
import SEPlayerCommon


// TODO: flush on notifications
// AirPlay error on  and APAC error via 
final class AVFAudioRenderer2: AVFBaseRenderer2 {
    private let renderSynchronizer: AVSampleBufferRenderSynchronizer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let decodeBufferQueue: TypedCMBufferQueue<CMSampleBuffer>

    private let bufferedOutputSamples: TypedCMBufferQueue<CMSampleBuffer>
    private var currentPosition: CMTime = .zero
    private var allowPositionDiscontinuity: Bool = false
    private var playbackParameters: PlaybackParameters = .default

    private var renderingStatus: NSKeyValueObservation?

    @UnfairLocked private var isAirPlayOutput = false

    init(
        queue: any Queue,
        clock: SEClock,
        renderSynchronizer: AVSampleBufferRenderSynchronizer
    ) throws {
        self.renderSynchronizer = renderSynchronizer
        audioRenderer = AVSampleBufferAudioRenderer()
        try decodeBufferQueue = .init()
        try bufferedOutputSamples = .init()
        super.init(queue: queue, trackType: .audio, clock: clock)

        renderingStatus = audioRenderer.observe(\.status, changeHandler: { renderer, _ in
//            switch renderer.status {
//            case .unknown:
//                print("🏙️ RENDERER STATUS UNKNOWN")
//            case .rendering:
//                print("🏙️ RENDERER STATUS rendering")
//            case .failed:
//                print("🏙️ RENDERER STATUS FAILED, \(renderer.error)")
//            }
        })

        renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

//    override func willChangeStream(oldStream: (any SampleStream)?, newStream: inout any SampleStream) throws {
//        if newStream is BufferedSampleStreamWrapper { return }
//        newStream = BufferedSampleStreamWrapper(stream: newStream)
//    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        try super.onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        renderSynchronizer.addRenderer(audioRenderer)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rendererFasFlushed),
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer
        )

        isAirPlayOutput = AVAudioSession.isAirPlayOutput
        let session = AVAudioSession.sharedInstance()
        print("⛑️ ON ENABLED output = \(session.currentRoute.outputs), prefer = \(session.preferredIOBufferDuration), dur = \(session.ioBufferDuration)")
    }

    override func onDisabled() {
        super.onDisabled()
        NotificationCenter.default.removeObserver(self)
        renderSynchronizer.removeRenderer(audioRenderer, at: .invalid)
        try? decodeBufferQueue.reset()
        try? bufferedOutputSamples.reset()
    }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        guard format.sampleMimeType?.isAudio == true else {
            return .create(formatSupport: .unsupportedType)
        }

        return .create(formatSupport: .handled)
    }

//    override func handleMessage(_ message: RendererMessage) throws {
//        switch message {
//        case let .setVideoOutput(renderer):
////            let didHasRenderers = renderersStorage.hasOutput
//            renderersStorage.addRenderer(renderer)
////            if !didHasRenderers {
////                onOutputChanged()
////            }
//        case let .removeVideoOutput(renderer):
//            renderersStorage.removeRenderer(renderer)
////            if !renderersStorage.hasOutput {
////                onOutputRemoved()
////            }
//        case let .setControlTimebase(timebase):
//            renderersStorage.setControlTimebase(timebase)
//        default:
//            try super.handleMessage(message)
//        }
//    }

    override func getMediaClock() -> (any MediaClock)? {
        self
    }

    override func getTimebase() -> CMTimebase? {
        renderSynchronizer.timebase
    }

//    override func isEnded() -> Bool {
//        guard lastSampleTime.isValid else {
//            return false
//        }
//
//        return renderSynchronizer.currentTime() >= lastSampleTime
//    }

    override func isReady() -> Bool {
        audioRenderer.hasSufficientMediaDataForReliablePlaybackStart || didReadStreamToEnd()
    }

    override func onStarted() throws {
        renderSynchronizer.rate = playbackParameters.playbackRate
    }

    override func onStopped() {
        renderSynchronizer.rate = .zero
        updateCurrentPosition()
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        try decodeBufferQueue.reset()
        audioRenderer.flush()
        try bufferedOutputSamples.reset()
        renderSynchronizer.setRate(renderSynchronizer.rate, time: position)
        currentPosition = position
    }

    override func onInputFormatChanged(_ format: Format) throws {
        guard outputMode == .decode else { return }
    }

    override func getDecodeBufferQueue() throws -> TypedCMBufferQueue<CMSampleBuffer>? {
        switch outputMode {
        case .passthrough:
            nil
        case .decode:
            decodeBufferQueue
        }
    }

    override func feedInputBuffer(readStream: (ReadFlags) throws -> SampleStreamReadResult) throws -> Bool {
        guard outputMode == .decode else {
            throw ErrorBuilder(errorDescription: "") // TODO: real error
        }

        fatalError()
    }

    override func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool {
//        if positionForAutoFlush.isValid, positionForAutoFlush < buffer.outputPresentationTimeStamp {
//            positionForAutoFlush = .invalid
//            return true
//        }

        audioRenderer.enqueue(buffer)

        if !isAirPlayOutput {
            try bufferedOutputSamples.enqueue(buffer)
            let currentTime = renderSynchronizer.currentTime()
            while let sample = bufferedOutputSamples.head {
                if sample.outputPresentationTimeStamp < currentTime {
                    _ = bufferedOutputSamples.dequeue()
                } else {
                    break
                }
            }
        }

        return audioRenderer.isReadyForMoreMediaData
    }

    override func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) {
        audioRenderer.requestMediaDataWhenReady(on: queue.queue, using: callback)
    }

    override func stopRequestingOutputMediaData() {
        audioRenderer.stopRequestingMediaData()
    }

    private func updateCurrentPosition() {
        let newCurrentPosition = renderSynchronizer.currentTime()
        if newCurrentPosition.isValid {
            currentPosition = allowPositionDiscontinuity ? newCurrentPosition : max(currentPosition, newCurrentPosition)
            allowPositionDiscontinuity = false
        }
    }

    @objc
    private func rendererFasFlushed(_ notification: Notification) {
        if isAirPlayOutput != AVAudioSession.isAirPlayOutput {
            delegate?.onRendererError(
                self,
                error: .init(
                    type: .renderer(.error(.init(rendererName: "", rendererIndex: 0, rendererFormat: nil, rendererFormatSupport: .handled))),
                    mediaPeriodId: .init(),
                    isRecoverable: true
                )
            )
        } else if AVAudioSession.isAirPlayOutput {
            delegate?.onRendererError(
                self,
                error: .init(
                    type: .renderer(.rendererRequiresFlush),
                    mediaPeriodId: .init(),
                    isRecoverable: true
                )
            )
        } else {
            let currentTime = renderSynchronizer.currentTime()
            while let sampleBuffer = bufferedOutputSamples.dequeue() {
                if sampleBuffer.outputPresentationTimeStamp >= currentTime {
                    audioRenderer.enqueue(sampleBuffer)
                }
            }
        }
//        audioRenderer.flush()
//        print("")
//
    }
}

extension AVFAudioRenderer2: MediaClock {
    func setPlaybackParameters(new playbackParameters: PlaybackParameters) {
        self.playbackParameters = playbackParameters

        if renderSynchronizer.rate != 0 {
            renderSynchronizer.rate = playbackParameters.playbackRate
        }
    }

    func getPlaybackParameters() -> PlaybackParameters {
        playbackParameters
    }

    func getPosition() -> CMTime {
        if getState() == .started {
            updateCurrentPosition()
        }

        return currentPosition
    }
}

final class AVQueuedSampleBufferRenderingWrapper: NSObject {
    private let queue: Queue
    private let renderer: AVQueuedSampleBufferRendering

    init(queue: Queue, renderer: AVQueuedSampleBufferRendering) {
        self.queue = queue
        self.renderer = renderer
    }

    nonisolated(nonsending) public func enqueue(_ sampleBuffer: CMSampleBuffer) async throws -> EnqueueResult {
        fatalError()

    }

//    private func
}

extension AVQueuedSampleBufferRenderingWrapper {
    enum EnqueueResult {
        case enqueued
        case enqueuedWithDecodeFailures([any Error])
        case cancelledDueToFlush
        case cancelledDueToFlushRequiredToResume(any Error)
        case cancelledDueToError(any Error)
    }
}

private extension AVAudioSession {
    static var isAirPlayOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .airPlay }
    }
}
