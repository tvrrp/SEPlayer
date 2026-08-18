//
//  AVFVideoRenderer2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import CoreMedia
import SEPlayerCommon

final class AVFVideoRenderer2: AVFBaseRenderer2 {
    private let renderersStorage: VideoSampleBufferRenderersStorage
    private let videoDecoder: VTDecoder2
    private let decodeBufferQueue: TypedCMBufferQueue<CMSampleBuffer>

    private let joiningTimer: DispatchSourceTimer

    private var currentOutputFormat: CMFormatDescription?

    private var pendingRenderer: (any VideoSampleBufferRenderer)?
    private var joiningDeadline = CMTime.invalid

    private var firstJoiningSampleQueued = true
    private var lowWaterMarkToken: CMBufferQueue.TriggerToken?

    private var isFirstSampleQueued = false

    private let lowWaterMark: CMTime
    private let highWaterMark: CMTime

    init(
        queue: any Queue,
        clock: any SEClock
    ) throws {
        renderersStorage = try VideoSampleBufferRenderersStorage(queue: queue)
        decodeBufferQueue = try .init()
        videoDecoder = VTDecoder2(decodeQueue: queue, outputBufferQueue: decodeBufferQueue)

        lowWaterMark = CMTime(value: 3, timescale: 30) // 3 frames @ 30fps = 100ms
        highWaterMark = CMTime(value: 5, timescale: 30) // 5 frames @ 30fps = 167ms

        joiningTimer = DispatchSource.makeTimerSource(queue: queue.queue)

        super.init(queue: queue, trackType: .video, clock: clock)

        renderersStorage.delegate = self
        joiningTimer.setEventHandler { [weak self] in
            guard let self else { return }

            renderersStorage.setIsHidden(false)
        }

        joiningTimer.resume()
    }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        guard format.sampleMimeType?.isVideo == true else {
            return .create(formatSupport: .unsupportedType)
        }

        return try super.supportsFormat(format)
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setVideoOutput(renderer):
            let didHasRenderers = renderersStorage.hasOutput
            if didHasRenderers, isFirstSampleQueued {
                pendingRenderer = renderer
                renderer.setIsHidden(true)
                renderer.setControlTimebase(renderersStorage.controlTimebase)
                changeOutputMode(to: .decode)

                firstJoiningSampleQueued = false
                if let controlTimebase = renderersStorage.controlTimebase {
                    joiningDeadline = controlTimebase.time + CMTime(seconds: 0.5, preferredTimescale: 1000)
                }
            } else {
                renderersStorage.addRenderer(renderer)
            }
//            if !didHasRenderers {
//                onOutputChanged()
//            }
        case let .removeVideoOutput(renderer):
            renderersStorage.removeRenderer(renderer)
            renderer.flush(removeImage: true)

            if pendingRenderer === renderer {
                pendingRenderer = nil
            }

            if renderersStorage.hasOutput {
                changeOutputMode(to: .passthrough)
            }
//            if !renderersStorage.hasOutput {
//                onOutputRemoved()
//            }
        case let .setControlTimebase(timebase):
            renderersStorage.setControlTimebase(timebase)
        default:
            break
        }

        try super.handleMessage(message)
    }

//    override func onOutputModeChanged() {
//        if let pendingRenderer {
//            print("🏈🏈🏈🏈🏈🏈")
//            print("🏈 ON OUTPUT CHANGED, ")
//            print("🏈🏈🏈🏈🏈🏈")
//            renderersStorage.addRenderer(pendingRenderer)
//            self.pendingRenderer = nil
//        }
//    }

    override func isReady() -> Bool {
        if joiningDeadline != .invalid,
           let timebase = renderersStorage.controlTimebase,
           joiningDeadline > timebase.time {
            return true
        } else {
            joiningDeadline = .invalid
            return renderersStorage.hasSufficientMediaDataForReliablePlaybackStart
                && renderersStorage.isReadyForDisplay
        }
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        isFirstSampleQueued = false
        videoDecoder.flush()
        try decodeBufferQueue.reset()
        renderersStorage.flush()
    }

//    override func onStreamChanged(formats: [Format], startPosition: CMTime, offset: CMTime, mediaPeriodId: MediaPeriodId) throws {
//        outputMode = .decode
//        try super.onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
//    }

    override func onDisabled() {
        super.onDisabled()
        renderersStorage.flush(removeImage: true)
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

//        while try feedInputBufferInternal(stream) {}
//        return result && decodeBufferQueue.duration < highWaterMark
        guard videoDecoder.getNumberOfFramesBeingDecoded() < 10 else {
            return false
        }

        if let lowWaterMarkToken {
            try! decodeBufferQueue.removeTrigger(lowWaterMarkToken)
            self.lowWaterMarkToken = nil
        }

        switch try readStream([]) {
        case .nothingRead:
            return false
        case let .didReadFormat(format):
//            print()
            return true
        case let .didReadBuffer(buffer):
//            if isFirstSampleQueued {
//                buffer.flags.insert(.firstSample)
//            }
            if !firstJoiningSampleQueued {
                if let controlTimebase = renderersStorage.controlTimebase {
                    try controlTimebase.addTimer(joiningTimer)
                    try controlTimebase.setTimerNextFireTime(joiningTimer, fireTime: buffer.outputPresentationTimeStamp)
                }

                firstJoiningSampleQueued = true
            }

            try videoDecoder.queueInputBuffer(buffer: buffer, flags: [])

            let maxPts = videoDecoder.getMaxOutputPtsOfFramesBeingDecoded()
            let minPts = videoDecoder.getMinOutputPtsOfFramesBeingDecoded()

            var enqueuedDuration = decodeBufferQueue.duration
            if maxPts.isValid, minPts.isValid {
                enqueuedDuration = enqueuedDuration + (maxPts - minPts)
            }

//            print("🏈 ENQUEUED, inDecodeSamples = \(videoDecoder.getNumberOfFramesBeingDecoded()), maxPts = \(maxPts.seconds), minPts = \(minPts.seconds), enqueuedDuration = \(enqueuedDuration.seconds)")

            if enqueuedDuration >= highWaterMark {
                try installLowWaterMarkToken()
            }

            return enqueuedDuration < highWaterMark
        }
    }

    override func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool {
        if outputMode == .passthrough {
            switch currentOutputFormat {
            case let .some(formatDescription):
                guard let otherFormatDescription = buffer.formatDescription else {
                    fallthrough
                }

                if formatDescription.equalTo(otherFormatDescription) == false {
                    fallthrough
                }
            case .none:
                buffer.attachments.merge([
                    kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding as String : true
                ], mode: .shouldPropagate)
            }

            currentOutputFormat = buffer.formatDescription
        }

        isFirstSampleQueued = true
        renderersStorage.enqueue(buffer)

        if let pendingRenderer {
            // TODO: mark buffers as doNotDisplay
            pendingRenderer.enqueue(buffer)

            // TODO: add timer that will hide view
            if pendingRenderer.hasSufficientMediaDataForReliablePlaybackStart && pendingRenderer.isReadyForDisplay {
//                print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER ATTACHING 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//                print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER ATTACHING 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//                print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER ATTACHING 🌈🌈🌈🌈🌈🌈🌈🌈🌈")
//                print("🌈🌈🌈🌈🌈🌈🌈🌈 RENDERER ATTACHING 🌈🌈🌈🌈🌈🌈🌈🌈🌈")

                renderersStorage.addRenderer(pendingRenderer)
                self.pendingRenderer = nil
            }
        }

        if outputMode == .passthrough, buffer.flags.contains(.lastSample) {
            let drainSampleBuffer = try CMSampleBuffer.marker(with: [
                kCMSampleBufferAttachmentKey_DrainAfterDecoding as String: kCFBooleanTrue as Any
            ])
            renderersStorage.enqueue(drainSampleBuffer)

            let postNotification = try CMSampleBuffer.marker(with: [
                kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed as String : [:] as CFDictionary
            ])
            renderersStorage.enqueue(postNotification)

            let endOfMediaSampleBuffer = try CMSampleBuffer.marker(
                with: [
                    kCMSampleBufferAttachmentKey_EmptyMedia as String: kCFBooleanTrue as Any,
                    kCMSampleBufferAttachmentKey_PermanentEmptyMedia as String: kCFBooleanTrue as Any
                ],
                sampleTiming: CMSampleTimingInfo(
                    duration: .zero,
                    presentationTimeStamp: buffer.outputPresentationTimeStamp,
                    decodeTimeStamp: .invalid
                )
            )
            renderersStorage.enqueue(endOfMediaSampleBuffer)
            return false
        }

        let isReadyForMoreMediaData = renderersStorage.isReadyForMoreMediaData
//        if outputMode == .decode {
//            print("🏈 RENDER BUFFER, pts = \(buffer.presentationTimeStamp.seconds), isReady = \(isReadyForMoreMediaData)")
//        }

        return isReadyForMoreMediaData
    }

    override func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) {
        renderersStorage.requestMediaDataWhenReady(on: queue.queue, using: callback)
    }

    override func stopRequestingOutputMediaData() {
        renderersStorage.stopRequestingMediaData()
    }

    private func installLowWaterMarkToken() throws {
        guard lowWaterMarkToken == nil else { return }

        lowWaterMarkToken = try! getDecodeBufferQueue()?.installTrigger(
            condition: .whenDurationBecomesLessThanOrEqualTo(lowWaterMark)
        ) { [weak self] token in
            guard let self else { return }

            queue.justDispatch { self.readInputStream() }
        }
    }
}

extension AVFVideoRenderer2: VideoSampleBufferRendererDelegate {
    var isolation: any Actor { queue.playerActor() }

    func renderer(_ renderer: any VideoSampleBufferRenderer, didFailedRenderingWith error: any Error, isolation: isolated any Actor) {
        print(error)
        if renderer.requiresFlushToResumeDecoding {
            delegate?.onRendererError(
                self,
                error: .init(
                    type: .renderer(.rendererRequiresFlush),
                    mediaPeriodId: .init(),
                    isRecoverable: true
                )
            )
        } else {
            fatalError("\(error)")
        }
    }

    func renderer(_ renderer: any VideoSampleBufferRenderer, didChangeReadyForDisplay: Bool, isolation: isolated any Actor) {
//        print("🏈🏈🏈🌈🌈 ============== RENDERER IS READY = \(didChangeReadyForDisplay) ============== 🌈🌈🏈🏈🏈")
        rendererDidChangeIsReady()
    }
}
