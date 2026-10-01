//
//  AVFVideoRenderer2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import CoreMedia
import SEPlayerCommon

final class AVFVideoRenderer2: AVFBaseRenderer2 {
    private let displayLayers: DisplayLayersStorage
    private let videoDecoder: VTDecoder2
    private let decodeBufferQueue: TypedCMBufferQueue<CMSampleBuffer>

    private let lowWaterMark: CMTime
    private let highWaterMark: CMTime

    private var currentOutputFormat: CMFormatDescription?
    private var lowWaterMarkToken: CMBufferQueue.TriggerToken?

    init(
        queue: any Queue,
        clock: any SEClock
    ) throws {
        displayLayers = DisplayLayersStorage(queue: queue)
        decodeBufferQueue = try .init()
        videoDecoder = VTDecoder2(decodeQueue: queue, outputBufferQueue: decodeBufferQueue)

        lowWaterMark = CMTime(value: 3, timescale: 30) // 3 frames @ 30fps = 100ms
        highWaterMark = CMTime(value: 5, timescale: 30) // 5 frames @ 30fps = 167ms

        super.init(queue: queue, trackType: .video, clock: clock)
        displayLayers.delegate = self
    }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        guard format.sampleMimeType?.isVideo == true else {
            return .create(formatSupport: .unsupportedType)
        }

        return try super.supportsFormat(format)
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setVideoOutput(output):
            displayLayers.addOutput(output)
        case let .removeVideoOutput(output):
            displayLayers.removeOutput(output)
        case let .setControlTimebase(timebase):
            displayLayers.setControlTimebase(timebase)
        default:
            break
        }

        try super.handleMessage(message)
    }

    override func isReady() -> Bool {
        displayLayers.hasSufficientMediaDataForReliablePlaybackStart && displayLayers.isReadyForDisplay
    }


    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        videoDecoder.flush()
        try decodeBufferQueue.reset()
        displayLayers.flush()
    }

    override func onDisabled() {
        super.onDisabled()
        displayLayers.flush(removeImage: true)
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
        case .didReadFormat:
            return true
        case let .didReadBuffer(buffer):
            try videoDecoder.queueInputBuffer(buffer: buffer, flags: [])

            let maxPts = videoDecoder.getMaxOutputPtsOfFramesBeingDecoded()
            let minPts = videoDecoder.getMinOutputPtsOfFramesBeingDecoded()

            var enqueuedDuration = decodeBufferQueue.duration
            if maxPts.isValid, minPts.isValid {
                enqueuedDuration = enqueuedDuration + (maxPts - minPts)
            }

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

        displayLayers.enqueue(buffer)

        // End of media only when nothing follows; the next item continues on the same layers.
        if outputMode == .passthrough, buffer.flags.contains(.lastSample), isCurrentStreamFinal() {
            let drainSampleBuffer = try CMSampleBuffer.marker(with: [
                kCMSampleBufferAttachmentKey_DrainAfterDecoding as String: kCFBooleanTrue as Any
            ])
            displayLayers.enqueue(drainSampleBuffer)

            let postNotification = try CMSampleBuffer.marker(with: [
                kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed as String : [:] as CFDictionary
            ])
            displayLayers.enqueue(postNotification)

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
            displayLayers.enqueue(endOfMediaSampleBuffer)
            return false
        }

        return displayLayers.isReadyForMoreMediaData
    }

    override func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) {
        displayLayers.requestMediaDataWhenReady(on: queue.queue, using: callback)
    }

    override func stopRequestingOutputMediaData() {
        displayLayers.stopRequestingMediaData()
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
        rendererDidChangeIsReady()
    }
}
