//
//  AVFBaseRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 19.07.2026.
//

import AVFoundation
import SEPlayerCommon

class AVFBaseRenderer: BaseSERenderer {
    enum OutputMode {
        case passthrough
        case decode
    }

    var outputMode: OutputMode = .passthrough {
        didSet { onOutputModeChanged() }
    }

    /// Whether the output failed in the background, and is looked at again once the app is in the foreground.
    /// Meanwhile the renderer counts as ready, so the other tracks play on, and drops what its stream holds behind the
    /// clock, which the output couldn't show anyway.
    private(set) final var isOutputDirty = false

    override var isRecoveringWhileTimelineAdvances: Bool { recoveringOutput }

    /// Whether failures of the output in the background wait for the foreground: the system takes video decoders
    /// away there, and gives them back on return.
    var defersRecoveryInBackground: Bool { false }
    /// How much enqueued ahead of the clock is enough to start, before the output stops asking for more; `nil` to wait
    /// until it does.
    var minimumPreroll: CMTime? { nil }

    private let stallTimer: TimebaseTimer
    private let rendererFinishedTimer: TimebaseTimer

    private var outputAvailableToken: CMBufferQueueTriggerToken?
    private var sampleQueueToken: QueueTriggerToken?
    /// Whether the output has had enough since the last reset: it stopped asking for media data, or the stream
    /// ended. It's the renderer's readiness, and only the pipeline changes it: the output filling, or running dry.
    private var prerollReached = false
    private var lastEnqueuedSample: CMTimeRange = .invalid
    private var controlTimebase: CMTimebase?

    private var currentError: SEPlaybackError?
    private var pumpGeneration: UInt64 = 0
    private var pumpSuspended = false
    private var recoveringOutput = false
    private var recoveryTimer: DispatchSourceTimer?
    private var recoveryAttempt: UInt64 = 0
    /// Bumped each time the output gets dirty, so a foreground check meant for an earlier time does nothing.
    private var dirtyGeneration: UInt64 = 0
    private var dirtySkipTimer: DispatchSourceTimer?

    /// What one pump has enqueued so far, for the log.
    private var batchSampleCount = 0
    private var batchDuration: CMTime = .zero
    private var batchRange: CMTimeRange = .invalid

    private var pendingOutputMode: OutputMode?
    /// What was read after the samples of the last buffer enqueued, and didn't join them: the next pump starts with it.
    private var carriedRead: SampleStreamReadResult?
    private var rendererAtEndOfStream = false
    private var isRenderingEnded = false

    override init(queue: any Queue, trackType: TrackType, clock: any SEClock) {
        stallTimer = TimebaseTimer(queue: queue.queue)
        rendererFinishedTimer = TimebaseTimer(queue: queue.queue)

        super.init(queue: queue, trackType: trackType, clock: clock)

        stallTimer.setEventHandler { [weak self] in
            guard let self, !pumpSuspended, getState() != .disabled else {
                return
            }
            outputDidRunDry()
        }

        rendererFinishedTimer.setEventHandler { [weak self] in
            guard let self, !pumpSuspended, getState() != .disabled else {
                return
            }
            guard rendererAtEndOfStream, lastEnqueuedSample.isValid,
                  let controlTimebase, lastEnqueuedSample.end <= controlTimebase.time else {
                return
            }

            SELogger.info(logTopic, "\(name) finished rendering at \(controlTimebase.time.seconds)")
            isRenderingEnded = true
            delegate?.rendererDidFinishRendering(self)
        }
    }

    deinit {
        recoveryTimer?.cancel()
    }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        let isPlayable = Self.playabilityQueries(for: format).contains(where: AVURLAsset.isPlayableExtendedMIMEType)

        return if isPlayable {
            .create(
                formatSupport: .handled,
                adaptiveSupport: .seamless,
                hardwareAccelerationSupport: .supported,
                decoderSupport: .primary
            )
        } else {
            .create(formatSupport: .unsupportedSubtype)
        }
    }

    /// The extended MIME types that tell whether the system plays `format`.
    private static func playabilityQueries(for format: AnyFormat) -> [String] {
        var mimeTypes = [String]()
        if let containerMimeType = format.containerMimeType {
            mimeTypes.append(containerMimeType.rawValue)
        }
        if let sampleMimeType = format.sampleMimeType {
            mimeTypes.append(sampleMimeType.rawValue)
        }

        // A stream read without a container that names its codec, as MP3 or AC-3 in MPEG-TS, is asked about by the
        // codec of its type.
        var codecs = format.codecs
        if codecs == nil, let sampleMimeType = format.sampleMimeType {
            codecs = Codecs.codec(forSampleMimeType: sampleMimeType)
        }
        guard let codecs else { return mimeTypes }

        // The last query asks about the codec alone, whatever the container.
        mimeTypes.append(MimeTypes.videoMP4.rawValue)
        let parameter = Codecs.withParameterSetsOutOfBand(codecs)
        return mimeTypes.map { "\($0); codecs=\"\(parameter)\"" }
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setTimeSource(source) = message, source?.timebase !== controlTimebase {
            controlTimebase = source?.timebase
            try stallTimer.setTimebase(controlTimebase)
            try rendererFinishedTimer.setTimebase(controlTimebase)
            // Timers set on the old timebase are gone with it.
            if getState() == .started { try armPlaybackTimers() }
        }

        try super.handleMessage(message)
    }

    override func isEnded() -> Bool { isRenderingEnded }

    override func isReady() -> Bool {
        prerollReached || isRenderingEnded || isOutputDirty
    }

    override func willChangeStream(oldStream: (any SampleStream)?, newStream: inout any SampleStream) throws {
        pumpGeneration &+= 1
        carriedRead = nil
        stopRequestingOutputMediaData()
        cancelOutputRecovery()
        if let outputAvailableToken {
            try? getDecodeBufferQueue()?.removeTrigger(outputAvailableToken)
            self.outputAvailableToken = nil
        }
        if let oldStream, let sampleQueueToken {
            self.sampleQueueToken = nil
            oldStream.removeTrigger(sampleQueueToken)
        }
    }

    override func onStreamChanged(
        formats: [AnyFormat],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        pumpSuspended = false
        isRenderingEnded = false
        rendererAtEndOfStream = false

        try installInputQueueTrigger()
        if outputMode == .decode {
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
        cancelOutputRecovery()
        try resetOutputPipeline()
        resumeMediaData()
    }

    /// Invalidates callbacks already dispatched before a flush, seek, or stream replacement.
    final func suspendMediaData() {
        logBatchFinished("suspended")
        pumpGeneration &+= 1
        pumpSuspended = true
        stopRequestingOutputMediaData()
        if let sampleQueueToken {
            getStream()?.removeTrigger(sampleQueueToken)
            self.sampleQueueToken = nil
        }
        if let outputAvailableToken {
            try? getDecodeBufferQueue()?.removeTrigger(outputAvailableToken)
            self.outputAvailableToken = nil
        }
        stallTimer.cancel()
        rendererFinishedTimer.cancel()
    }

    final func resetOutputPipeline() throws {
        SELogger.debug(logTopic, "\(name) flushes its output")
        clearDirtyOutput()
        suspendMediaData()
        currentError = nil
        prerollReached = false
        isRenderingEnded = false
        rendererAtEndOfStream = false
        lastEnqueuedSample = .invalid
        carriedRead = nil
    }

    final func resumeMediaData() {
        pumpSuspended = false
        schedulePump()
        // Suspending removed the trigger of the decoded frames: without it nothing would read them again.
        if outputMode == .decode {
            try? installOutputQueueTriggers()
        }
    }

    final func requestRecovery(_ reason: RendererRecoveryReason, error: Error? = nil, position: CMTime = .invalid) {
        guard getState() != .disabled else { return }
        // In the background a flush could fail again at once, and nothing needs the output there. It is looked at
        // again in the foreground.
        if defersRecoveryInBackground, reason == .decoderRequiresFlush || reason == .outputFailed,
           ApplicationActivity.shared.isInBackground {
            markOutputDirty(reason: reason, error: error, position: position)
            return
        }
        clearDirtyOutput()
        let context = getRecoveryContext()
        SELogger.info(
            .recovery,
            "\(name) recovery=\(reason) generation=\(context.generation) "
                + "period=\(String(describing: context.mediaPeriodId)) readPosition=\(getReadingPosition().seconds) "
                + "position=\(position.seconds) error=\(String(describing: error))"
        )
        suspendMediaData()
        if reason == .automaticFlush {
            beginOutputRecovery()
        } else {
            cancelOutputRecovery()
        }
        let request = RendererRecoveryRequest(
            reason: reason,
            context: context,
            underlyingError: error,
            position: position
        )
        delegate?.rendererNeedsRecovery(self, request: request)
    }

    /// Leaves a failure in the background for the foreground.
    private func markOutputDirty(reason: RendererRecoveryReason, error: Error?, position: CMTime) {
        cancelOutputRecovery()
        guard !isOutputDirty else { return }
        SELogger.info(
            .recovery,
            "\(name) output failed in the background (\(reason)): checked again in the foreground"
        )
        isOutputDirty = true
        dirtyGeneration &+= 1
        let timer = DispatchSource.makeTimerSource(queue: queue.queue)
        timer.setEventHandler { [weak self] in self?.skipStreamToClock() }
        timer.schedule(deadline: .now() + Self.dirtySkipInterval, repeating: Self.dirtySkipInterval)
        dirtySkipTimer = timer
        timer.activate()
        // The player may wait on this renderer: it counts as ready now.
        delegate?.rendererFinishedPreroll(self)

        let generation = dirtyGeneration
        ApplicationActivity.shared.whenInForeground { [weak self] in
            guard let self else { return }
            queue.justDispatch { [weak self] in
                guard let self, isOutputDirty, dirtyGeneration == generation, getState() != .disabled else {
                    return
                }
                clearDirtyOutput()
                guard outputNeedsRecovery() else {
                    SELogger.info(.recovery, "\(name) output works again in the foreground")
                    schedulePump()
                    return
                }
                SELogger.info(.recovery, "\(name) recovers its output in the foreground")
                requestRecovery(reason, error: error, position: position)
            }
        }
    }

    private func clearDirtyOutput() {
        isOutputDirty = false
        dirtySkipTimer?.cancel()
        dirtySkipTimer = nil
    }

    /// Drops the samples behind the clock, so the stream doesn't hold on to them, nor the player stop loading for
    /// the other tracks.
    private func skipStreamToClock() {
        guard isOutputDirty, getState() != .disabled, let stream = getStream(),
              let time = controlTimebase?.time, time.isNumeric else {
            return
        }
        let skipped = (try? stream.skipData(position: time - getStreamOffset())) ?? 0
        if skipped > 0 {
            SELogger.verbose(.recovery, "\(name) skipped \(skipped) samples to \(time.seconds) with a dirty output")
        }
    }

    final func beginOutputRecovery() {
        guard !recoveringOutput else { return }
        recoveringOutput = true
        recoveryAttempt &+= 1
        let attempt = recoveryAttempt
        let timer = DispatchSource.makeTimerSource(queue: queue.queue)
        timer.setEventHandler { [weak self] in
            guard let self, recoveringOutput, recoveryAttempt == attempt else {
                return
            }
            requestRecovery(.recoveryTimedOut, error: RendererRecoveryError.timedOut)
        }
        timer.schedule(deadline: .now() + Self.outputRecoveryTimeout)
        recoveryTimer = timer
        timer.activate()
    }

    final func cancelOutputRecovery() {
        recoveryAttempt &+= 1
        recoveringOutput = false
        recoveryTimer?.cancel()
        recoveryTimer = nil
    }

    private func schedulePump(output: Bool = false) {
        let generation = pumpGeneration
        queue.justDispatch { [weak self] in
            guard let self, generation == pumpGeneration, !pumpSuspended,
                  getState() != .disabled else {
                return
            }
            if output { feedOutputStream() } else { readInputStream() }
        }
    }

    final func enqueuedDuration(aheadOf time: CMTime) -> CMTime {
        guard time.isNumeric, lastEnqueuedSample.start.isNumeric else {
            return .zero
        }
        let end = lastEnqueuedSample.end.isNumeric ? lastEnqueuedSample.end : lastEnqueuedSample.start
        return max(.zero, end - time)
    }

    override func onStarted() throws {
        try super.onStarted()
        try armPlaybackTimers()
    }

    private func armPlaybackTimers() throws {
        guard !pumpSuspended, let controlTimebase, lastEnqueuedSample.end.isNumeric else {
            return
        }
        // stop() disarms these timers, including when buffering stops playback.
        // Re-arm them on resume even if no new sample has arrived in the meantime.
        if rendererAtEndOfStream {
            if lastEnqueuedSample.end <= controlTimebase.time {
                isRenderingEnded = true
                delegate?.rendererDidFinishRendering(self)
            } else {
                try rendererFinishedTimer.setFireTime(lastEnqueuedSample.end)
            }
        } else {
            if lastEnqueuedSample.end <= controlTimebase.time {
                outputDidRunDry()
            } else {
                try stallTimer.setFireTime(lastEnqueuedSample.end)
            }
        }
    }

    override func onStopped() {
        stallTimer.cancel()
        rendererFinishedTimer.cancel()
    }

    override func onDisabled() {
        clearDirtyOutput()
        cancelOutputRecovery()
        suspendMediaData()
        carriedRead = nil
        currentError = nil
        inputFormatDidChange(nil)
    }

    final func changeOutputMode(to outputMode: OutputMode) {
        guard self.outputMode != outputMode else { return }
        if getState() == .disabled {
            self.outputMode = outputMode
        } else {
            pendingOutputMode = outputMode
        }
    }

    func onOutputModeChanged() {}

    /// The buffer to enqueue for `buffer`, just read. An output that takes several samples in one buffer joins those
    /// that follow it here, read with ``readFollowingBuffer(if:)``.
    func outputBuffer(startingWith buffer: CMSampleBuffer) throws -> CMSampleBuffer { buffer }

    /// Reads the buffer that follows the last one read, if `joins` takes it. Anything else read, such as a buffer of
    /// another format or the end of the stream, is what the next pump starts with.
    final func readFollowingBuffer(if joins: (CMSampleBuffer) -> Bool) throws -> CMSampleBuffer? {
        assert(carriedRead == nil)
        let result = try readSource()
        switch result {
        case .nothingRead:
            return nil
        case let .didReadBuffer(buffer) where joins(buffer):
            return buffer
        case .didReadBuffer,
             .didReadFormat:
            carriedRead = result
            return nil
        }
    }

    private func takeCarriedRead() -> SampleStreamReadResult? {
        defer { carriedRead = nil }
        return carriedRead
    }

    // MARK: - For subclasses

    /// Whether the output still needs recovering once the app is in the foreground, after a failure in the background.
    func outputNeedsRecovery() -> Bool { true }

    func feedInputBuffer(readStream: (ReadFlags) throws -> SampleStreamReadResult) throws -> Bool {
        fatalError("To override")
    }

    func getDecodeBufferQueue() throws -> TypedCMBufferQueue<CMSampleBuffer>? { fatalError("To override") }
    func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool { fatalError("To override") }
    func onInputFormatChanged(_ format: AnyFormat) throws { fatalError("To override") }
    /// Called with each format the renderer reads, and `nil` once it is disabled: what it renders from now on.
    func inputFormatDidChange(_ format: AnyFormat?) {}
    func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) { fatalError("To override") }
    func stopRequestingOutputMediaData() { fatalError("To override") }

    func createPlaybackError(_ error: Error) -> SEPlaybackError {
        .createForRenderer(
            error,
            rendererName: name,
            rendererIndex: -1,
            trackType: trackType,
            format: getStreamFormats().first,
            mediaPeriodId: getRecoveryContext().mediaPeriodId ?? .init()
        )
    }

    /// Ends playback with `error` if the media can't be decoded; recovers the output from anything else.
    final func reportFailure(_ error: Error) {
        guard getState() != .disabled, currentError == nil else { return }
        guard RendererFailure(error) == .decoding else {
            SELogger.warning(.recovery, "\(name) output failed, recovering: \(error as NSError)")
            requestRecovery(.outputFailed, error: error)
            return
        }
        SELogger.error(logTopic, "\(name) failed to decode: \(error as NSError)")
        cancelOutputRecovery()
        suspendMediaData()
        let playbackError = createPlaybackError(error)
        currentError = playbackError
        delegate?.onRendererError(self, error: playbackError)
    }

    /// The clock reached the end of what was enqueued, before the end of the stream: the output played out
    /// everything and has to fill up again.
    private func outputDidRunDry() {
        guard !pumpSuspended, !isOutputDirty, getState() != .disabled, prerollReached, !rendererAtEndOfStream else {
            return
        }
        SELogger.info(logTopic, "\(name) ran dry after \(lastEnqueuedSample.end.seconds), \(logTimes)")
        prerollReached = false
        delegate?.rendererPipelineStalled(self)
    }

    final func readInputStream() {
        assert(queue.isCurrent())
        guard currentError == nil, !pumpSuspended, getState() != .disabled else {
            return
        }

        if let sampleQueueToken {
            getStream()?.removeTrigger(sampleQueueToken)
            self.sampleQueueToken = nil
        }

        do {
            while try pumpReadStream() {}
        } catch {
            reportFailure(error)
        }
    }

    private func pumpReadStream() throws -> Bool {
        // The output mode changes at a keyframe: decoding starts with it, and passing through waits until the
        // decoded frames before it are out.
        if let pendingOutputMode,
           case let .didReadBuffer(buffer) = try carriedRead ?? readSource(readFlags: .peek),
           buffer.flags.contains(.keyframe) {
            switch pendingOutputMode {
            case .decode:
                outputMode = pendingOutputMode
                self.pendingOutputMode = nil
                schedulePump(output: true)
                try stallTimer.setFireTime(.invalid)
                return true
            case .passthrough:
                return false
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

        switch try takeCarriedRead() ?? readSource() {
        case .nothingRead:
            logBatchFinished("input empty")
            try installInputQueueTrigger()

            if lastEnqueuedSample.isValid {
                try stallTimer.setFireTime(lastEnqueuedSample.end)
            }
            return false
        case let .didReadFormat(format):
            SELogger.info(logTopic, "\(name) input format: \(format)")
            try onInputFormatChanged(format)
            inputFormatDidChange(format)
            return true
        case let .didReadBuffer(buffer):
            try stallTimer.setFireTime(.invalid)

            // End of stream stops reading every time, not only the first. Fed on as a sample, it
            // comes straight back from the queue and loops forever on the shared player queue.
            if buffer.flags.contains(.endOfStream) {
                logBatchFinished("end of stream")
                guard !rendererAtEndOfStream else { return false }
                rendererAtEndOfStream = true

                // Rendering ends when the last sample has played out. A timebase timer set behind the
                // current time never fires, and after a seek to the end nothing may have been
                // enqueued at all, so then it has ended already.
                let end = lastEnqueuedSample.isValid ? lastEnqueuedSample.end : .invalid
                SELogger.debug(logTopic, "\(name) read the end of the stream, last sample ends at \(end.seconds)")
                if let controlTimebase, end.isValid, end > controlTimebase.time {
                    try rendererFinishedTimer.setFireTime(end)
                } else {
                    isRenderingEnded = true
                    delegate?.rendererDidFinishRendering(self)
                }
                // All there is was enqueued: the output has enough.
                markPrerollReached()
                return false
            }

            // Frames that end before the seek position are decoded but not shown. The frame covering
            // the position stays visible, or there would be nothing to show at that time. Marked on
            // the buffer itself: `singleSampleBuffers()` returns copies.
            if trackType == .video, buffer.duration.isNumeric,
               buffer.outputPresentationTimeStamp + buffer.duration <= getLastResetPosition() {
                for index in 0 ..< buffer.numSamples {
                    buffer.perSampleAttachments[index][.doNotDisplay] = true
                }
            }

            let enqueued = try outputBuffer(startingWith: buffer)
            let isReadyForMoreMediaData = try feedOutputBuffer(enqueued)
            lastEnqueuedSample = .init(start: enqueued.outputPresentationTimeStamp, duration: enqueued.duration)

            recordEnqueued(enqueued)
            markPrerollReachedIfEnoughEnqueued()

            if !isReadyForMoreMediaData {
                logBatchFinished("output full")
                let generation = pumpGeneration
                requestOutputMediaDataWhenReady { [weak self] in
                    guard let self, generation == pumpGeneration, !pumpSuspended else {
                        return
                    }
                    logMediaDataRequested()
                    stopRequestingOutputMediaData()
                    readInputStream()
                }

                markPrerollReached()
            }

            return isReadyForMoreMediaData
        }
    }

    private func feedOutputStream() {
        assert(queue.isCurrent())
        guard currentError == nil, !pumpSuspended, getState() != .disabled else {
            return
        }

        do {
            stopRequestingOutputMediaData()
            if let token = outputAvailableToken {
                try getDecodeBufferQueue()?.removeTrigger(token)
                outputAvailableToken = nil
            }

            while try pumpOutputStream() {}
        } catch {
            reportFailure(error)
        }
    }

    private func pumpOutputStream() throws -> Bool {
        guard let decodeBufferQueue = try getDecodeBufferQueue() else {
            return false
        }

        guard let buffer = decodeBufferQueue.dequeue() else {
            if let pendingOutputMode, pendingOutputMode == .passthrough {
                outputMode = pendingOutputMode
                self.pendingOutputMode = nil
                schedulePump()
                try stallTimer.setFireTime(.invalid)
                return false
            }

            logBatchFinished("input empty")
            try installOutputQueueTriggers()

            if lastEnqueuedSample.isValid {
                try stallTimer.setFireTime(lastEnqueuedSample.end)
            }
            return false
        }

        try stallTimer.setFireTime(.invalid)
        let isReadyForMoreMediaData = try feedOutputBuffer(buffer)
        lastEnqueuedSample = .init(start: buffer.outputPresentationTimeStamp, duration: buffer.duration)
        recordEnqueued(buffer)
        markPrerollReachedIfEnoughEnqueued()

        if !isReadyForMoreMediaData {
            logBatchFinished("output full")
            let generation = pumpGeneration
            requestOutputMediaDataWhenReady { [weak self] in
                guard let self, generation == pumpGeneration, !pumpSuspended else {
                    return
                }
                logMediaDataRequested()
                stopRequestingOutputMediaData()
                feedOutputStream()
            }

            markPrerollReached()
        }

        return isReadyForMoreMediaData
    }

    /// Marks the preroll reached once ``minimumPreroll`` is enqueued ahead of the clock, while the output goes on asking.
    private func markPrerollReachedIfEnoughEnqueued() {
        guard !prerollReached, let minimumPreroll else { return }
        let time = controlTimebase?.time ?? getLastResetPosition()
        if enqueuedDuration(aheadOf: time) >= minimumPreroll {
            markPrerollReached()
        }
    }

    /// The output stopped asking for media data: it has enough to start. Tells the player once; it has no timer,
    /// so without this it would not look again.
    private func markPrerollReached() {
        cancelOutputRecovery()
        guard !prerollReached else { return }
        SELogger.debug(logTopic, "\(name) preroll reached, enqueued to \(lastEnqueuedSample.end.seconds), \(logTimes)")
        prerollReached = true
        delegate?.rendererFinishedPreroll(self)
    }

    // MARK: - Pump log

    /// Whether the topic of the renderer logs each batch: video enqueues frame by frame, so only at its most verbose.
    private var logsPump: Bool { SELogger.isEnabled(logTopic, .verbose) }

    private var logTimes: String {
        // The renderer's own timebase is the synchronizer's for audio; the control timebase is the player's.
        String(
            format: "host=%.3f renderer=%.3f player=%.3f",
            CACurrentMediaTime(),
            getTimebase()?.time.seconds ?? .nan,
            controlTimebase?.time.seconds ?? .nan
        )
    }

    private func logMediaDataRequested() {
        guard logsPump else { return }
        SELogger.verbose(logTopic, "\(name) pump: requestMediaDataWhenReady fired \(logTimes)")
    }

    private func recordEnqueued(_ buffer: CMSampleBuffer) {
        guard logsPump else { return }
        batchSampleCount += buffer.numSamples
        if buffer.duration.isNumeric { batchDuration = batchDuration + buffer.duration }
        let range = CMTimeRange(start: buffer.outputPresentationTimeStamp, duration: buffer.duration)
        batchRange = batchRange.isValid ? batchRange.union(range) : range
    }

    /// Logs what the pump enqueued since the last time it stopped, if anything.
    private func logBatchFinished(_ reason: String) {
        guard logsPump, batchSampleCount > 0 else { return }
        SELogger.verbose(logTopic, String(
            format: "%@ pump: finished (%@) %@ enqueued=%d samples duration=%.3f range=%.3f..%.3f",
            name, reason, logTimes, batchSampleCount, batchDuration.seconds,
            batchRange.start.seconds, batchRange.end.seconds
        ))
        batchSampleCount = 0
        batchDuration = .zero
        batchRange = .invalid
    }

    private func installInputQueueTrigger() throws {
        // After the end of the stream there is nothing to wait for: marking the stream final or
        // replacing it wakes the renderer.
        guard sampleQueueToken == nil, !didReadStreamToEnd(), let stream = getStream() else {
            return
        }

        let generation = pumpGeneration
        sampleQueueToken = stream.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] _ in
            guard let self else { return }

            queue.justDispatch { [weak self] in
                guard let self, generation == pumpGeneration else { return }
                schedulePump()
            }
        }
    }

    private func installOutputQueueTriggers() throws {
        guard outputAvailableToken == nil, let decodeBufferQueue = try getDecodeBufferQueue() else {
            return
        }

        let generation = pumpGeneration
        outputAvailableToken = try decodeBufferQueue.installTrigger(
            condition: .whenDataBecomesReady
        ) { [weak self] _ in
            guard let self else { return }

            queue.justDispatch { [weak self] in
                guard let self, generation == pumpGeneration else { return }
                schedulePump(output: true)
            }
        }
        // The trigger fires when frames become ready: frames already there wouldn't fire it.
        if !decodeBufferQueue.isEmpty {
            schedulePump(output: true)
        }
    }
}

private extension AVFBaseRenderer {
    /// How long an output may take to fill again after an automatic flush before the recovery counts as failed.
    static let outputRecoveryTimeout: TimeInterval = 5
    /// How often a renderer with a dirty output drops the samples behind the clock.
    static let dirtySkipInterval: TimeInterval = 1
}
