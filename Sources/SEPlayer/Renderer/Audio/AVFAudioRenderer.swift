import AVFoundation
import SEPlayerCommon

final class AVFAudioRenderer: AVFBaseRenderer {
    private let renderSynchronizer: any PlaybackSynchronizer
    private let outputFactory: () -> any AudioSampleBufferOutput
    private var audioOutput: any AudioSampleBufferOutput
    private let decodeBufferQueue: TypedCMBufferQueue<CMSampleBuffer>
    /// Makes the decoders of the decode output mode.
    private let decoderFactory: AudioDecoderFactory?
    /// The decoder of the decode output mode, or `nil` when nothing decodes the input format.
    private var audioDecoder: AudioDecoder?
    /// The format of the samples read last.
    private var inputFormat: AnyFormat?
    private var reinitializationState = DecoderReinitializationState.none
    /// Whether the decoder got samples since it was made or flushed: a decoder that did is drained before it is
    /// replaced, so the audio it holds still plays.
    private var decoderReceivedBuffers = false
    private var lowWaterMarkToken: CMBufferQueueTriggerToken?
    private var outputGeneration: UInt64 = 0
    private var effectiveRateObserver: NSObjectProtocol?
    private weak var eventListener: AudioRendererEventListener?
    /// Whether the renderer was started and the clock hasn't moved yet.
    private var isAwaitingPlaybackStart = false
    /// Sample rate and channel count of the last sample enqueued.
    private var enqueuedAudioFormat: (sampleRate: Float64, channels: UInt32)?
    /// The first sample of a new format, kept until just before it plays; see ``holdsBackNewFormat(_:)``.
    private var pendingPreroll: AudioPacketBatch?
    private var heldSample: CMSampleBuffer?
    private let heldSampleTimer: DispatchSourceTimer
    private var volume: Float = 1
    private var isMuted = false

    init(
        queue: any Queue,
        clock: SEClock,
        renderSynchronizer: any PlaybackSynchronizer,
        eventListener: AudioRendererEventListener? = nil,
        decoderFactory: AudioDecoderFactory? = nil,
        outputFactory: @escaping () -> any AudioSampleBufferOutput = { AVFAudioSampleBufferOutput() }
    ) throws {
        self.eventListener = eventListener
        self.decoderFactory = decoderFactory
        self.renderSynchronizer = renderSynchronizer
        self.outputFactory = outputFactory
        audioOutput = outputFactory()
        decodeBufferQueue = try .init()
        heldSampleTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        super.init(queue: queue, trackType: .audio, clock: clock)

        heldSampleTimer.setEventHandler { [weak self] in self?.enqueueHeldSample() }
        heldSampleTimer.activate()
        try renderSynchronizer.timebase.addTimer(heldSampleTimer)

        // The synchronizer may hold its clock after the rate is set; the clock's own rate tells when it moves.
        effectiveRateObserver = NotificationCenter.default.addObserver(
            forName: CMTimebase.effectiveRateChanged,
            object: renderSynchronizer.timebase,
            queue: nil
        ) { [weak self, queue] _ in
            queue.justDispatch { [weak self] in self?.effectiveRateDidChange() }
        }
    }

    deinit {
        effectiveRateObserver.map(NotificationCenter.default.removeObserver)
        try? renderSynchronizer.timebase.removeTimer(heldSampleTimer)
        heldSampleTimer.cancel()
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        try super.onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        observeOutput()
        audioOutput.attach(to: renderSynchronizer)
    }

    override func onDisabled() {
        super.onDisabled()
        audioOutput.flush()
        replaceOutput()
        releaseDecoder()
        inputFormat = nil
        try? decodeBufferQueue.reset()
        forgetAudioFormat()
    }

    override func onRelease() {
        super.onRelease()

        audioOutput.detach(from: renderSynchronizer)
    }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        guard format.trackType == .audio else {
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

    /// The player's clock starts, stops and moves the synchronizer; the audio only plays in it.
    override func getRenderSynchronizer() -> (any PlaybackSynchronizer)? { renderSynchronizer }

    override func onStarted() throws {
        try super.onStarted()
        isAwaitingPlaybackStart = true
        // The clock may move at once: then no change is left to notify.
        effectiveRateDidChange()
    }

    override func onStopped() {
        super.onStopped()
        isAwaitingPlaybackStart = false
    }

    /// Leaves the synchronizer's time alone: enabled ahead for the next item, the renderer must not move the time of
    /// the item still playing.
    override func onPositionReset(position: CMTime, joining: Bool) throws {
        try super.onPositionReset(position: position, joining: joining)
        try flushDecoder()
        try decodeBufferQueue.reset()
        audioOutput.flush()
        forgetAudioFormat()
    }

    override func handleMessage(_ message: RendererMessage) throws {
        switch message {
        case let .setAudioVolume(volume):
            self.volume = volume
            audioOutput.setVolume(volume, isMuted: isMuted)
        case let .setAudioIsMuted(isMuted):
            self.isMuted = isMuted
            audioOutput.setVolume(volume, isMuted: isMuted)
        default:
            break
        }
        try super.handleMessage(message)
    }

    override func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool {
        assert(queue.isCurrent())
        // A failed audio renderer stays failed: a new one takes its place.
        if reason == .mediaServicesWereReset || reason == .outputFailed {
            SELogger.info(.recovery, "\(name) rebuilds its output after \(reason)")
            suspendMediaData()
            forgetAudioFormat()
            replaceOutput()
            observeOutput()
            audioOutput.attach(to: renderSynchronizer)
            return false // The player coordinates re-preroll after hardware reconstruction.
        }
        guard reason == .automaticFlush else { return false }
        suspendMediaData()
        let currentTime = renderSynchronizer.currentTime()
        let readAhead = enqueuedDuration(aheadOf: currentTime)
        SELogger.verbose(
            .audio,
            "Audio refill time=\(currentTime.seconds) rate=\(renderSynchronizer.rate) "
                + "airPlay=\(audioOutput.isAirPlayActive) readAhead=\(readAhead.seconds)"
        )
        // Local replay cannot recover a synchronizer that stopped independently of
        // the player's renderer state. Let the player stop, re-preroll and restart it.
        if getState() == .started, renderSynchronizer.rate == 0 { return false }
        // Buffered AirPlay prerolls a second or more of output before it plays, and while the clock
        // runs that audio is already late. Re-preroll all tracks with the clock stopped instead.
        if audioOutput.isAirPlayActive { return false }
        guard currentTime.isNumeric, try rewindSourceForRecovery(to: currentTime) else {
            return false
        }
        // AVSampleBufferAudioRendererWasFlushedAutomatically recommends a serialized flush to
        // remove samples that survived concurrent enqueueing. A coordinated seek
        // flushes in onPositionReset instead, so it must not flush here as well.
        audioOutput.flush()
        forgetAudioFormat()
        try resetOutputPipeline()
        try flushDecoder()
        try decodeBufferQueue.reset()
        beginOutputRecovery()
        resumeMediaData()
        // Deliberately do not set the synchronizer's time or rate.
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

    override func inputFormatDidChange(_ format: AnyFormat?) {
        eventListener?.onAudioInputFormatChanged(format)
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
            if let audioDecoder { signalEndOfStream(to: audioDecoder) }
            return false
        case .waitEndOfStream:
            return false
        }

        // With enough decoded audio ahead, decoding goes on once the output took some of it.
        if let lowWaterMarkToken {
            try decodeBufferQueue.removeTrigger(lowWaterMarkToken)
            self.lowWaterMarkToken = nil
        }
        guard decodeBufferQueue.duration < Self.decodedAudioHighWaterMark else {
            lowWaterMarkToken = try decodeBufferQueue.installTrigger(
                condition: .whenDurationBecomesLessThanOrEqualTo(Self.decodedAudioLowWaterMark)
            ) { [weak self] _ in
                guard let self else { return }
                queue.justDispatch { [weak self] in self?.readInputStream() }
            }
            return false
        }

        switch try readStream([]) {
        case .nothingRead:
            return false
        case let .didReadFormat(format):
            try onInputFormatChanged(format)
            inputFormatDidChange(format)
            return true
        case let .didReadBuffer(buffer):
            // Nothing decodes the format.
            guard let audioDecoder else {
                throw RendererRecoveryError.unsupportedAudioDecoding
            }
            try audioDecoder.queueInputBuffer(buffer)
            decoderReceivedBuffers = true
            return true
        }
    }

    /// Joins the packets that follow `buffer` and are already in the stream: see ``AudioPacketBatch``.
    override func outputBuffer(startingWith buffer: CMSampleBuffer) throws -> CMSampleBuffer? {
        var candidate = pendingPreroll
        pendingPreroll = nil
        if candidate?.canAppend(buffer) == true {
            candidate?.append(buffer)
        } else {
            candidate = AudioPacketBatch(buffer)
        }
        guard var batch = candidate else { return buffer }
        while let next = try readFollowingBuffer(if: batch.canAppend) {
            batch.append(next)
        }
        if !batch.hasPlayableAudio {
            pendingPreroll = batch
            return nil
        }
        return try batch.makeSampleBuffer()
    }

    override func feedOutputBuffer(_ buffer: CMSampleBuffer) throws -> Bool {
        guard !holdsBackNewFormat(buffer) else { return false }
        try audioOutput.enqueue(buffer)
        return audioOutput.isReadyForMoreMediaData
    }

    override func requestOutputMediaDataWhenReady(_ callback: @Sendable @escaping () -> Void) {
        audioOutput.requestMediaDataWhenReady(on: queue.queue, using: callback)
    }

    override func stopRequestingOutputMediaData() { audioOutput.stopRequestingMediaData() }

    // MARK: - Output

    private func effectiveRateDidChange() {
        guard isAwaitingPlaybackStart, getState() == .started, renderSynchronizer.timebase.effectiveRate > 0 else {
            return
        }
        isAwaitingPlaybackStart = false
        delegate?.rendererDidStartPlayback(self)
    }

    private func observeOutput() {
        outputGeneration &+= 1
        let generation = outputGeneration
        audioOutput.observeEvents { [weak self] event in
            guard let self else { return }
            // The context is locked: notifications may arrive on any thread. The entire
            // flush/seek/enqueue transaction executes on the same queue as the pump.
            let context = getRecoveryContext()
            queue.justDispatch { [weak self] in
                guard let self, generation == outputGeneration,
                      context == getRecoveryContext(), getState() != .disabled else {
                    return
                }
                SELogger.info(.audio, "\(name) output event: \(event)")
                switch event {
                case let .recovery(reason, error): requestRecovery(reason, error: error)
                case let .flushedAutomatically(time):
                    // A player seek restarts from the first flushed sample with the clock stopped, so all
                    // flushed audio is still heard: always on AirPlay, and locally when the samples
                    // can't be replayed. A local refill keeps the clock and ignores it.
                    requestRecovery(.automaticFlush, position: time)
                case let .failure(error): reportFailure(error)
                }
            }
        }
    }

    /// Puts a new output in place of the current one, which may still be detaching: it isn't attached again.
    private func replaceOutput() {
        outputGeneration &+= 1
        audioOutput.stopObserving()
        audioOutput.detach(from: renderSynchronizer)
        audioOutput = outputFactory()
        audioOutput.setVolume(volume, isMuted: isMuted)
    }

    // MARK: - Decoder

    /// Keeps the decoder when it decodes `newFormat` too, and otherwise has the factory make one of the new format.
    private func updateDecoder(oldFormat: AnyFormat?, newFormat: AnyFormat) throws {
        guard let audioDecoder, let oldFormat else {
            try initializeDecoder(for: newFormat)
            return
        }
        // A decoder already waiting to be replaced is replaced by one of the latest format, once it is drained.
        guard reinitializationState == .none else { return }

        switch audioDecoder.canReuse(oldFormat: oldFormat, newFormat: newFormat) {
        case .yesWithoutReconfiguration:
            break
        case .no where decoderReceivedBuffers:
            // Drained first, so the audio it holds still plays; the factory then makes a decoder of the new format.
            reinitializationState = .signalEndOfStream
        case .no:
            releaseDecoder()
            try initializeDecoder(for: newFormat)
        }
    }

    private func initializeDecoder(for format: AnyFormat) throws {
        guard let decoderFactory, decoderFactory.supportsFormat(format).formatSupport == .handled else {
            SELogger.warning(.audio, "\(name) has no decoder for \(format.sampleMimeType?.rawValue ?? "?")")
            return
        }

        let decoder = try decoderFactory.createDecoder(
            format: format,
            mediaPeriodId: getMediaPeriodId(),
            decodeQueue: queue,
            outputBufferQueue: decodeBufferQueue
        )
        SELogger.info(.audio, "\(name) decodes \(format.sampleMimeType?.rawValue ?? "?") with \(decoder.name)")
        audioDecoder = decoder
    }

    private func releaseDecoder() {
        audioDecoder?.invalidate()
        audioDecoder = nil
        reinitializationState = .none
        decoderReceivedBuffers = false
    }

    /// Drops the packets being decoded. A decoder waiting to be replaced is replaced now: nothing of it is left to play.
    private func flushDecoder() throws {
        guard reinitializationState == .none else {
            releaseDecoder()
            if let inputFormat { try initializeDecoder(for: inputFormat) }
            return
        }

        audioDecoder?.flush()
        decoderReceivedBuffers = false
    }

    /// Tells the decoder its input ended, and replaces it once it output all the audio it holds.
    private func signalEndOfStream(to decoder: AudioDecoder) {
        reinitializationState = .waitEndOfStream
        decoder.signalEndOfStream { [weak self, weak decoder] in
            self?.queue.justDispatch { [weak self] in self?.decoderDidEndStream(decoder) }
        }
    }

    private func decoderDidEndStream(_ decoder: AudioDecoder?) {
        // A flush or a reset may have replaced the decoder meanwhile.
        guard reinitializationState == .waitEndOfStream, let decoder, decoder === audioDecoder else {
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

    // MARK: - Format changes

    /// Keeps the first sample of a new sample rate or channel count until just before it plays.
    ///
    /// The output plays a new format on a new audio queue, started for the time of its first sample. While the audio
    /// is stretched in time, at a rate other than 1, that queue's timeline already runs from when it is started, and
    /// the output then places its audio that much ahead of the clock, for as long as it plays. Enqueued long before
    /// its time, as the output reads ahead, the new format would play ahead by about as long. Enqueued a moment
    /// before, it is on time.
    ///
    /// - Returns: Whether `buffer` is kept; it is enqueued by ``enqueueHeldSample()``.
    private func holdsBackNewFormat(_ buffer: CMSampleBuffer) -> Bool {
        guard buffer.numSamples > 0,
              let description = buffer.formatDescription?.audioStreamBasicDescription else {
            return false
        }

        let format = (sampleRate: description.mSampleRate, channels: description.mChannelsPerFrame)
        let previous = enqueuedAudioFormat
        enqueuedAudioFormat = format

        guard let previous, previous.sampleRate != format.sampleRate || previous.channels != format.channels else {
            return false
        }

        let time = buffer.outputPresentationTimeStamp
        let enqueueTime = time - CMTime(
            seconds: Self.newFormatLead * Double(max(renderSynchronizer.rate, 1)),
            preferredTimescale: 1_000_000
        )

        guard renderSynchronizer.currentTime() < enqueueTime else {
            return false
        }

        SELogger.debug(
            .audio,
            "audio: format \(previous.sampleRate) Hz × \(previous.channels) → "
                + "\(format.sampleRate) Hz × \(format.channels) at \(time.seconds), kept until \(enqueueTime.seconds)"
        )
        heldSample = buffer
        suspendMediaData()
        try? renderSynchronizer.timebase.setTimerNextFireTime(heldSampleTimer, fireTime: enqueueTime)
        // The timer can be lost when the clock changes its source: the host time it is due backs it up.
        let rate = Double(renderSynchronizer.rate)
        if rate > 0 {
            let delay = (enqueueTime - renderSynchronizer.currentTime()).seconds / rate
            queue.after(max(delay, 0) + Self.heldSampleTimerSlack) { [weak self] in
                guard let self, heldSample === buffer, renderSynchronizer.currentTime() >= enqueueTime else {
                    return
                }
                enqueueHeldSample()
            }
        }
        return true
    }

    private func enqueueHeldSample() {
        guard let heldSample else { return }
        self.heldSample = nil
        try? renderSynchronizer.timebase.setTimerNextFireTime(heldSampleTimer, fireTime: .invalid)
        guard getState() != .disabled else { return }
        SELogger.debug(.audio, "audio: new format enqueued at \(renderSynchronizer.currentTime().seconds)")
        do {
            try audioOutput.enqueue(heldSample)
        } catch {
            reportFailure(error)
            return
        }
        resumeMediaData()
    }

    /// A flush or a seek drops a kept sample: the samples come again from the source.
    private func forgetAudioFormat() {
        heldSample = nil
        pendingPreroll = nil
        enqueuedAudioFormat = nil
        try? renderSynchronizer.timebase.setTimerNextFireTime(heldSampleTimer, fireTime: .invalid)
    }
}

private extension AVFAudioRenderer {
    /// How long before its time the first sample of a new format is enqueued: enough for the output to set up the
    /// new format and start it on time.
    static let newFormatLead: CFTimeInterval = 0.06
    /// How long after the kept sample is due the host-time backup of its timer fires.
    static let heldSampleTimerSlack: CFTimeInterval = 0.01
    /// The duration of decoded audio at which decoding goes on.
    static let decodedAudioLowWaterMark = CMTime(value: 1, timescale: 2)
    /// The duration of decoded audio at which decoding pauses.
    static let decodedAudioHighWaterMark = CMTime(value: 1, timescale: 1)
}
