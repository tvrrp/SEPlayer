//
//  AVFVideoRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import CoreMedia
import SEPlayerCommon
import VideoToolbox

final class AVFVideoRenderer: AVFBaseRenderer {
    private let displayLayers: DisplayLayersStorage
    /// Makes the decoders of the decode output mode.
    private let decoderFactory: VideoDecoderFactory?
    /// The decoder of the decode output mode, or `nil` when nothing decodes the input format.
    private var videoDecoder: VideoDecoder?
    /// The format of the samples read last.
    private var inputFormat: AnyFormat?
    private var reinitializationState = DecoderReinitializationState.none
    /// Whether the decoder got samples since it was made or flushed: a decoder that did is drained before it is
    /// replaced, so the frames it holds still show.
    private var decoderReceivedBuffers = false
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
    /// When the position last reset, until a frame shows: for the logs of how long the frame took.
    private var resetTime: DispatchTime?
    /// Samples sent to the decoder since the position reset.
    private var samplesReadSinceReset = 0
    /// Frames given to the layers since the position reset or the output recovered. Until one is, the layers can still
    /// say they are ready for display from the frame shown before the flush.
    private var framesEnqueuedSinceReset = 0

    /// Whether the layers show a frame enqueued since the position reset.
    private var showsEnqueuedFrame: Bool {
        framesEnqueuedSinceReset > 0 && displayLayers.isReadyForDisplay
    }

    override var defersRecoveryInBackground: Bool { true }

    /// As much as the audio output asks for before it is full. The video output asks for two seconds or more, which
    /// after a seek outside the buffer is that much more to download before playback.
    override var minimumPreroll: CMTime? { CMTime(value: 1, timescale: 1) }

    init(
        queue: any Queue,
        clock: any SEClock,
        eventListener: VideoRendererEventListener? = nil,
        decoderFactory: VideoDecoderFactory? = nil
    ) throws {
        self.eventListener = eventListener
        self.decoderFactory = decoderFactory
        displayLayers = DisplayLayersStorage(queue: queue)
        decodeBufferQueue = try .init()
        super.init(queue: queue, trackType: .video, clock: clock)
        displayLayers.delegate = self
    }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        guard format.trackType == .video else {
            return .create(formatSupport: .unsupportedType)
        }

        // The system plays what it can, and a decoder of the factory decodes the rest.
        let systemSupport = try super.supportsFormat(format)
        if systemSupport.formatSupport == .handled {
            return systemSupport
        }
        // Only the system output decrypts protected samples: a decoder of the factory can't.
        if format.encryption != nil {
            return .create(formatSupport: .unsupportedDrm)
        }
        guard let decoderFactory else { return systemSupport }
        return decoderFactory.supportsFormat(format)
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
        isEnded() || isOutputDirty || (super.isReady() && showsEnqueuedFrame)
    }

    /// A layer that failed or waits for a flush needs one; a decoder lost in the background, a new one from a
    /// keyframe.
    override func outputNeedsRecovery() -> Bool {
        displayLayers.needsFlush || outputMode == .decode
    }

    override func hasPresentedOutput() -> Bool {
        isEnded() || showsEnqueuedFrame
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        renderedFirstFrame = false
        try flushDecoder()
        try decodeBufferQueue.reset()
        displayLayers.flush()
        compressedSampleTimes.reset()
        resetTime = .now()
        samplesReadSinceReset = 0
        framesEnqueuedSinceReset = 0
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
        releaseDecoder()
        inputFormat = nil
        displayLayers.flush(removeImage: !preservesDisplayedImageOnDisable)
        displayLayers.setTimeSource(nil)
    }

    override func onRelease() {
        super.onRelease()

        displayLayers.flush(removeImage: true)
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
            videoDecoder?.invalidate()
        }
        try flushDecoder()
        try decodeBufferQueue.reset()
        displayLayers.flush()
        compressedSampleTimes.reset()
        framesEnqueuedSinceReset = 0
        beginOutputRecovery()
        resumeMediaData()
        return true
    }

    /// Keeps the output mode: passing through goes on while the system plays the format, and a format it doesn't
    /// play is decoded from the next keyframe; decoding goes on, with the decoder or one of the new format.
    override func onInputFormatChanged(_ format: AnyFormat) throws {
        let oldFormat = inputFormat
        inputFormat = format
        switch targetOutputMode {
        case .passthrough:
            guard try super.supportsFormat(format).formatSupport != .handled else {
                return
            }
            try updateDecoder(oldFormat: oldFormat, newFormat: format)
            changeOutputMode(to: .decode)
        case .decode:
            // TODO: pass a format protected by DRM through to the system output, which alone decrypts it, once DRM is
            // supported.
            try updateDecoder(oldFormat: oldFormat, newFormat: format)
        }
    }

    override func getDecodeBufferQueue() throws -> TypedCMBufferQueue<CMSampleBuffer>? {
        outputMode == .decode ? decodeBufferQueue : nil
    }

    override func feedInputBuffer(readStream: (ReadFlags) throws -> SampleStreamReadResult) throws -> Bool {
        guard outputMode == .decode else {
            throw ErrorBuilder.illegalState()
        }

        switch reinitializationState {
        case .none:
            break
        case .signalEndOfStream:
            if let videoDecoder { signalEndOfStream(to: videoDecoder) }
            return false
        case .waitEndOfStream:
            return false
        }

        if let videoDecoder, videoDecoder.getNumberOfFramesBeingDecoded() >= Self.maxFramesBeingDecoded {
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
            try onInputFormatChanged(format)
            inputFormatDidChange(format)
            return true
        case let .didReadBuffer(buffer):
            guard let videoDecoder else {
                // Nothing decodes the format.
                throw VideoDecoderError.failed(kVTVideoDecoderUnsupportedDataFormatErr)
            }

            try videoDecoder.queueInputBuffer(buffer)
            decoderReceivedBuffers = true
            compressedSampleTimes.add(buffer)
            samplesReadSinceReset += 1
            if samplesReadSinceReset == 1, let resetTime {
                SELogger.debug(
                    .video,
                    "\(name) decodes its first sample after the reset, at \(buffer.outputPresentationTimeStamp.seconds), "
                        + "\(resetTime.distance(to: .now()).totalMilliseconds)ms after it"
                )
            }

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
        framesEnqueuedSinceReset += 1
        if framesEnqueuedSinceReset == 1, let resetTime {
            SELogger.debug(
                .video,
                "\(name) enqueues its first frame after the reset, at \(buffer.outputPresentationTimeStamp.seconds), "
                    + "\(resetTime.distance(to: .now()).totalMilliseconds)ms after it"
            )
        }
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
        if outputMode == .decode, let videoDecoder {
            // Frames still decoding, or decoded and not yet shown, come out in their own order.
            let decoding = videoDecoder.getMinOutputPtsOfFramesBeingDecoded()
            if decoding.isNumeric { bound = min(bound, decoding) }
            let decoded = decodeBufferQueue.minPresentationTimeStamp
            if decoded.isNumeric { bound = min(bound, decoded) }
        }
        displayLayers.expectMinimumUpcomingPresentationTime(bound)
    }

    // MARK: - Decoder

    /// Keeps the decoder when it decodes `newFormat` too, and otherwise has the factory make one of the new format.
    private func updateDecoder(oldFormat: AnyFormat?, newFormat: AnyFormat) throws {
        guard let videoDecoder, let oldFormat else {
            try initializeDecoder(for: newFormat)
            return
        }
        // A decoder already waiting to be replaced is replaced by one of the latest format, once it is drained.
        guard reinitializationState == .none else { return }

        switch videoDecoder.canReuse(oldFormat: oldFormat, newFormat: newFormat) {
        case .yesWithoutReconfiguration:
            break
        case .no where decoderReceivedBuffers:
            // Drained first, so the frames it holds still show; the factory then makes a decoder of the new format.
            reinitializationState = .signalEndOfStream
        case .no:
            releaseDecoder()
            try initializeDecoder(for: newFormat)
        }
    }

    private func initializeDecoder(for format: AnyFormat) throws {
        guard let decoderFactory, decoderFactory.supportsFormat(format).formatSupport == .handled else {
            SELogger.warning(.video, "\(name) has no decoder for \(format.sampleMimeType?.rawValue ?? "?")")
            return
        }

        let decoder = try decoderFactory.createDecoder(
            format: format,
            mediaPeriodId: getMediaPeriodId(),
            decodeQueue: queue,
            outputBufferQueue: decodeBufferQueue
        )
        SELogger.info(.video, "\(name) decodes \(format.sampleMimeType?.rawValue ?? "?") with \(decoder.name)")
        videoDecoder = decoder
    }

    private func releaseDecoder() {
        videoDecoder?.invalidate()
        videoDecoder = nil
        reinitializationState = .none
        decoderReceivedBuffers = false
    }

    /// Drops the frames being decoded. A decoder waiting to be replaced is replaced now: nothing of it is left to show.
    private func flushDecoder() throws {
        guard reinitializationState == .none else {
            releaseDecoder()
            if let inputFormat { try initializeDecoder(for: inputFormat) }
            return
        }

        videoDecoder?.flush()
        decoderReceivedBuffers = false
    }

    /// Tells the decoder its input ended, and replaces it once it output every frame it holds.
    private func signalEndOfStream(to decoder: VideoDecoder) {
        reinitializationState = .waitEndOfStream
        decoder.signalEndOfStream { [weak self, weak decoder] in
            self?.queue.justDispatch { [weak self] in self?.decoderDidEndStream(decoder) }
        }
    }

    private func decoderDidEndStream(_ decoder: VideoDecoder?) {
        // A flush or a reset may have replaced the decoder meanwhile.
        guard reinitializationState == .waitEndOfStream, let decoder, decoder === videoDecoder else {
            return
        }

        releaseDecoder()
        do {
            if let inputFormat { try initializeDecoder(for: inputFormat) }
            readInputStream()
        } catch {
            reportFailure(error)
        }
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
        // A change that comes after a flush, about the frame shown before it, isn't the frame of the new position.
        guard framesEnqueuedSinceReset > 0 else { return }
        if !renderedFirstFrame, getState() != .disabled {
            SELogger.info(.video, "\(name) shows its first frame")
            renderedFirstFrame = true
            eventListener?.onRenderedFirstFrame()
        }
        if displayLayers.isReadyForDisplay {
            SELogger.verbose(.display, "A frame shows")
            if let resetTime {
                SELogger.debug(
                    .video,
                    "\(name) shows a frame \(resetTime.distance(to: .now()).totalMilliseconds)ms after the reset, "
                        + "\(samplesReadSinceReset) samples decoded, \(framesEnqueuedSinceReset) frames enqueued"
                )
                self.resetTime = nil
            }
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
