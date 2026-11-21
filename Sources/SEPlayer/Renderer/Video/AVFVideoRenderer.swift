//
//  AVFVideoRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import CoreMedia
import SEPlayerCommon

final class AVFVideoRenderer: AVFBaseRenderer {
    private let displayLayers: DisplayLayersStorage
    private let videoDecoder: VTDecoder
    private let decodeBufferQueue: TypedCMBufferQueue<CMSampleBuffer>

    private var currentOutputFormat: CMFormatDescription?
    private var lowWaterMarkToken: CMBufferQueueTriggerToken?
    private var preservesDisplayedImageOnDisable = false
    /// Applied to the layers only while enabled: a disabled renderer left in the synchronizer would hold the audio
    /// back, waiting for video that never comes.
    private var timeSource: RendererTimeSource?
    private weak var eventListener: VideoRendererEventListener?
    /// The size of the frames last queued to show.
    private var reportedVideoSize: VideoSize?
    /// Whether a frame showed since the renderer was enabled or its position reset.
    private var renderedFirstFrame = false
    /// Failures to decode the media since a frame last showed. A flush gets past one that a lost reference or a
    /// broken sample caused; one that comes back each time is in the media.
    private var decodingFailuresWithoutFrame = 0
    /// Decode times of the compressed samples given out so far: enqueued as they are, or sent to the decoder.
    private var compressedSampleTimes = DecodeOrderTimes()

    override var defersRecoveryInBackground: Bool { true }

    /// As much as the audio output asks for before it is full. The video output asks for two seconds or more, which
    /// after a seek outside the buffer is that much more to download before playback.
    override var minimumPreroll: CMTime? { CMTime(value: 1, timescale: 1) }

    init(
        queue: any Queue,
        clock: any SEClock,
        eventListener: VideoRendererEventListener? = nil
    ) throws {
        self.eventListener = eventListener
        displayLayers = DisplayLayersStorage(queue: queue)
        decodeBufferQueue = try .init()
        videoDecoder = VTDecoder(decodeQueue: queue, outputBufferQueue: decodeBufferQueue)
        super.init(queue: queue, trackType: .video, clock: clock)
        displayLayers.delegate = self
    }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        guard format.trackType == .video else {
            return .create(formatSupport: .unsupportedType)
        }

        return try super.supportsFormat(format)
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setPreservesDisplayedImageOnDisable(preserve):
            preservesDisplayedImageOnDisable = preserve
        case let .setVideoOutput(output):
            displayLayers.addOutput(output)
        case let .removeVideoOutput(output):
            displayLayers.removeOutput(output)
        case let .setTimeSource(source):
            timeSource = source
            if getState() != .disabled { displayLayers.setTimeSource(source) }
        default:
            break
        }

        try super.handleMessage(message)
    }

    /// Ready once a second of frames is enqueued, or the output is full, and the frame at the current position is on
    /// screen, so a seek completes only when its frame is shown. A stream that ended has nothing more to show.
    override func isReady() -> Bool {
        isEnded() || isOutputDirty || (super.isReady() && displayLayers.isReadyForDisplay)
    }

    /// A layer that failed or waits for a flush needs one; a decoder lost in the background, a new one from a
    /// keyframe.
    override func outputNeedsRecovery() -> Bool {
        displayLayers.needsFlush || outputMode == .decode
    }

    override func hasPresentedOutput() -> Bool {
        isEnded() || displayLayers.isReadyForDisplay
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        renderedFirstFrame = false
        videoDecoder.flush()
        try decodeBufferQueue.reset()
        displayLayers.flush()
        compressedSampleTimes.reset()
    }

    override func onStreamChanged(
        formats: [AnyFormat],
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
        // The next stream may lead its decode times by another amount, and may start with frames before its start
        // position, behind the bound promised from the last one.
        compressedSampleTimes.reset()
        displayLayers.resetPresentationTimeExpectation()
    }

    override func onOutputModeChanged() {
        SELogger.info(.video, "\(name) output mode \(outputMode)")
        compressedSampleTimes.reset()
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        try super.onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        renderedFirstFrame = false
        displayLayers.setTimeSource(timeSource)
    }

    override func onDisabled() {
        super.onDisabled()
        displayLayers.flush(removeImage: !preservesDisplayedImageOnDisable)
        displayLayers.setTimeSource(nil)
    }

    override func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool {
        guard reason == .decoderRequiresFlush || reason == .outputFailed else {
            return false
        }
        SELogger.info(.recovery, "\(name) flushes its output and reloads from \(position.seconds) after \(reason)")
        suspendMediaData()
        guard try rewindSourceForRecovery(to: position) else { return false }
        try resetOutputPipeline()
        if reason == .outputFailed {
            // The system may have taken the decoder away: the next keyframe starts a new one.
            videoDecoder.invalidate()
        } else {
            videoDecoder.flush()
        }
        try decodeBufferQueue.reset()
        displayLayers.flush()
        compressedSampleTimes.reset()
        beginOutputRecovery()
        resumeMediaData()
        return true
    }

    override func onInputFormatChanged(_ format: AnyFormat) throws {}

    override func getDecodeBufferQueue() throws -> TypedCMBufferQueue<CMSampleBuffer>? {
        outputMode == .decode ? decodeBufferQueue : nil
    }

    override func feedInputBuffer(readStream: (ReadFlags) throws -> SampleStreamReadResult) throws -> Bool {
        guard outputMode == .decode else { throw ErrorBuilder.illegalState() }
        guard videoDecoder.getNumberOfFramesBeingDecoded() < Self.maxFramesBeingDecoded else {
            return false
        }

        if let lowWaterMarkToken {
            try decodeBufferQueue.removeTrigger(lowWaterMarkToken)
            self.lowWaterMarkToken = nil
        }

        switch try readStream([]) {
        case .nothingRead:
            return false
        case let .didReadFormat(format):
            inputFormatDidChange(format)
            return true
        case let .didReadBuffer(buffer):
            try videoDecoder.queueInputBuffer(buffer: buffer, flags: [])
            compressedSampleTimes.add(buffer)

            let maxPts = videoDecoder.getMaxOutputPtsOfFramesBeingDecoded()
            let minPts = videoDecoder.getMinOutputPtsOfFramesBeingDecoded()

            var enqueuedDuration = decodeBufferQueue.duration
            if maxPts.isValid, minPts.isValid {
                enqueuedDuration = enqueuedDuration + (maxPts - minPts)
            }

            if enqueuedDuration >= Self.highWaterMark {
                try installLowWaterMarkToken()
            }

            return enqueuedDuration < Self.highWaterMark
        }
    }

    override func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool {
        if outputMode == .passthrough {
            // The first buffer, and each one of another format, starts the layer's decoder over.
            var continuesFormat = false
            if let currentOutputFormat, let format = buffer.formatDescription {
                continuesFormat = currentOutputFormat.equalTo(format)
            }
            if !continuesFormat {
                buffer.bufferAttachments[.resetDecoderBeforeDecoding] = true
            }
            currentOutputFormat = buffer.formatDescription
        }

        maybeReportVideoSize(of: buffer)
        displayLayers.enqueue(buffer)
        if outputMode == .passthrough {
            compressedSampleTimes.add(buffer)
        }
        promiseMinimumUpcomingPresentationTime()

        // End of media only when nothing follows; the next item continues on the same layers.
        if outputMode == .passthrough, buffer.flags.contains(.lastSample), isCurrentStreamFinal() {
            let drainSampleBuffer = try CMSampleBuffer.marker(with: [.drainAfterDecoding: true])
            displayLayers.enqueue(drainSampleBuffer)

            let postNotification = try CMSampleBuffer.marker(
                with: [.postNotificationWhenConsumed: [:] as CFDictionary]
            )
            displayLayers.enqueue(postNotification)

            let endOfMediaSampleBuffer = try CMSampleBuffer.marker(
                with: [.emptyMedia: true, .permanentEmptyMedia: true],
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

    override func inputFormatDidChange(_ format: AnyFormat?) {
        eventListener?.onVideoInputFormatChanged(format)
    }

    private func maybeReportVideoSize(of buffer: CMSampleBuffer) {
        guard let formatDescription = buffer.formatDescription, formatDescription.mediaType == .video else {
            return
        }
        let dimensions = formatDescription.presentationDimensions(usePixelAspectRatio: false, useCleanAperture: true)
        var pixelRatio: Float = 1
        let pixelAspectRatio = formatDescription
            .extensionValue(for: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any]
        let spacing = { (key: CFString) in (pixelAspectRatio?[key as String] as? NSNumber)?.floatValue }
        if let horizontal = spacing(kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing),
           let vertical = spacing(kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing),
           horizontal > 0, vertical > 0 {
            pixelRatio = horizontal / vertical
        }
        let videoSize = VideoSize(
            width: Int(dimensions.width.rounded()),
            height: Int(dimensions.height.rounded()),
            pixelWidthHeightRatio: pixelRatio
        )
        guard videoSize != reportedVideoSize else { return }
        SELogger.debug(.video, "\(name) video size \(videoSize.width)×\(videoSize.height), pixel ratio \(pixelRatio)")
        reportedVideoSize = videoSize
        eventListener?.onVideoSizeChanged(videoSize)
    }

    /// Tells the layers the lowest time the samples still to come can have, so the display can skip looking for new
    /// frames until then.
    private func promiseMinimumUpcomingPresentationTime() {
        guard var bound = compressedSampleTimes.minimumUpcomingPresentationTime else {
            return
        }
        if outputMode == .decode {
            // Frames still decoding, or decoded and not yet shown, come out in their own order.
            let decoding = videoDecoder.getMinOutputPtsOfFramesBeingDecoded()
            if decoding.isNumeric { bound = min(bound, decoding) }
            let decoded = decodeBufferQueue.minPresentationTimeStamp
            if decoded.isNumeric { bound = min(bound, decoded) }
        }
        displayLayers.expectMinimumUpcomingPresentationTime(bound)
    }

    private func installLowWaterMarkToken() throws {
        guard lowWaterMarkToken == nil else { return }

        lowWaterMarkToken = try getDecodeBufferQueue()?.installTrigger(
            condition: .whenDurationBecomesLessThanOrEqualTo(Self.lowWaterMark)
        ) { [weak self] _ in
            guard let self else { return }
            queue.justDispatch { [weak self] in self?.readInputStream() }
        }
    }
}

private extension AVFVideoRenderer {
    /// The duration of decoded frames at which decoding goes on: 3 frames at 30 fps.
    static let lowWaterMark = CMTime(value: 3, timescale: 30)
    /// The duration of decoded frames at which decoding pauses: 5 frames at 30 fps.
    static let highWaterMark = CMTime(value: 5, timescale: 30)
    /// How many frames the decoder works on at a time.
    static let maxFramesBeingDecoded = 10
    /// How many times in a row the same media may fail to decode before the failure ends playback.
    static let maxDecodingFailuresWithoutFrame = 3
}

extension AVFVideoRenderer: VideoSampleBufferRendererDelegate {
    var isolation: any Actor { queue.playerActor() }

    func renderer(
        _ renderer: any VideoSampleBufferRenderer,
        didFailRenderingWith error: any Error,
        isolation: isolated any Actor
    ) {
        let needsFlush = renderer.requiresFlushToResumeDecoding
        SELogger.warning(
            .display,
            "\(type(of: renderer)) failed rendering\(needsFlush ? ", needs a flush" : ""): \(error)"
        )
        guard needsFlush else {
            reportFailure(error)
            return
        }
        // Flushed every time it isn't the media; when it is, until the same media failed a few times in a row.
        if RendererFailure(error) == .decoding {
            decodingFailuresWithoutFrame += 1
            if decodingFailuresWithoutFrame >= Self.maxDecodingFailuresWithoutFrame {
                reportFailure(error)
                return
            }
        }
        requestRecovery(.decoderRequiresFlush, error: error)
    }

    func renderer(
        _ renderer: any VideoSampleBufferRenderer,
        didChangeReadyForDisplay: Bool,
        isolation: isolated any Actor
    ) {
        guard didChangeReadyForDisplay else { return }
        displayLayers.readyForDisplayDidChange()
        if !renderedFirstFrame, getState() != .disabled {
            SELogger.info(.video, "\(name) shows its first frame")
            renderedFirstFrame = true
            eventListener?.onRenderedFirstFrame()
        }
        if displayLayers.isReadyForDisplay {
            SELogger.verbose(.display, "A frame shows")
            decodingFailuresWithoutFrame = 0
            delegate?.rendererDidPresentOutput(self)
        }
        // The frame showing may be the last thing readiness waited for.
        guard isReady() else { return }
        delegate?.rendererFinishedPreroll(self)
    }
}

/// The lowest presentation time the compressed samples after those seen can have.
///
/// Samples come in decode order, with decode times that only grow, and a sample shows no earlier than it decodes,
/// less the largest amount a presentation time came before its decode time (edit lists, negative composition
/// offsets). A sample without a decode time leaves no bound until the next reset.
struct DecodeOrderTimes {
    private var lastDecodeTime = CMTime.invalid
    /// How far a presentation time came before its decode time at most.
    private var presentationLead = CMTime.zero
    private var hasUntimedSample = false

    var minimumUpcomingPresentationTime: CMTime? {
        guard !hasUntimedSample, lastDecodeTime.isNumeric else { return nil }
        return lastDecodeTime - presentationLead
    }

    mutating func add(_ buffer: CMSampleBuffer) {
        guard !hasUntimedSample, buffer.numSamples > 0 else { return }
        guard let timings = try? buffer.outputSampleTimings() else {
            hasUntimedSample = true
            return
        }
        for timing in timings {
            let decodeTime = timing.decodeTimeStamp
            let presentationTime = timing.presentationTimeStamp
            guard decodeTime.isNumeric, presentationTime.isNumeric else {
                hasUntimedSample = true
                return
            }
            lastDecodeTime = lastDecodeTime.isNumeric ? max(lastDecodeTime, decodeTime) : decodeTime
            presentationLead = max(presentationLead, decodeTime - presentationTime)
        }
    }

    mutating func reset() {
        self = DecodeOrderTimes()
    }
}
