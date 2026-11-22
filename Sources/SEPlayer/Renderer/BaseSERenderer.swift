//
//  BaseSERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.04.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.BaseRenderer
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import AVFoundation
import SEPlayerCommon

/// A base class for most ``SERenderer`` implementations.
///
/// It turns the state transitions of ``SERenderer`` into callbacks, and keeps the state values so that subclasses
/// don't track them:
///
/// - ``onEnabled(joining:mayRenderStartOfStream:)``, ``onStarted()``, ``onStopped()``, ``onDisabled()``,
///   ``onReset()`` and ``onRelease()`` are called for the matching ``SERenderer`` method.
/// - ``onStreamChanged(formats:startPosition:offset:mediaPeriodId:)`` is called both for the first stream, set when the
///   renderer is enabled, and for the streams that ``replaceStream(formats:stream:startPosition:offset:mediaPeriodId:)``
///   sets later.
/// - ``onPositionReset(position:joining:)`` is called both for the first reset, when the renderer is enabled, and for
///   the resets of ``resetPosition(new:)``.
/// - The current ``SampleStream`` is read with ``readSource(readFlags:)`` or skipped with ``skipSource(position:)``;
///   ``isSourceReady()`` says whether there are samples to read.
/// - The state is available from getters such as ``getLastResetPosition()``, ``getStreamOffset()`` and
///   ``getTimeline()``.
/// - The renderer calls ``onRendererCapabilitiesChanged()`` to tell the player that its capabilities changed, which
///   may select other tracks.
open class BaseSERenderer: SERenderer, RendererCapabilitiesResolver {
    public final var listener: RendererCapabilitiesListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }

    public final weak var delegate: SERendererDelegate?
    open var name: String { String(describing: type(of: self)) }
    public let trackType: TrackType
    /// The topic this renderer logs its own events under.
    open var logTopic: SELogTopic {
        switch trackType {
        case .audio: .audio
        case .video: .video
        case .text: .text
        default: .lifecycle
        }
    }

    public let queue: Queue
    private let lock: UnfairLock
    private let clock: SEClock
    private var timebase: CMTimebase?

    private weak var _listener: RendererCapabilitiesListener?
    private var state: SERendererState = .disabled
    private var sampleStream: SampleStream?
    private var formats: [AnyFormat] = []

    private var streamIsFinal: Bool = false

    private var lastResetPosition: CMTime = .zero
    private var readingPosition: CMTime = .positiveInfinity
    private var streamOffset: CMTime = .zero
    private var timeline: Timeline
    private var recoveryContext = RendererRecoveryContext(generation: 0, mediaPeriodId: nil)

    public init(queue: Queue, trackType: TrackType, clock: SEClock) {
        self.queue = queue
        self.trackType = trackType
        self.clock = clock
        lock = UnfairLock()
        timeline = emptyTimeline
    }

    public final func getCapabilities() -> RendererCapabilitiesResolver {
        self
    }

    open func handleMessage(_ message: RendererMessage) throws {}

    public final func getState() -> SERendererState { state }

    public final func getRecoveryContext() -> RendererRecoveryContext { lock.withLock { recoveryContext } }
    open var isRecoveringWhileTimelineAdvances: Bool { false }
    open func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool { false }

    private func invalidateRecovery(mediaPeriodId: MediaPeriodId? = nil) {
        lock.withLock {
            recoveryContext = .init(
                generation: recoveryContext.generation &+ 1,
                mediaPeriodId: mediaPeriodId ?? recoveryContext.mediaPeriodId
            )
        }
    }

    /// Unlike a user seek, output recovery retains the final-stream marker and the clock.
    public final func rewindSourceForRecovery(to position: CMTime) throws -> Bool {
        guard let sampleStream else { return false }
        guard case .success = try sampleStream.seekWithinBuffer(to: position - streamOffset) else {
            return false
        }
        readingPosition = position
        lastResetPosition = position
        return true
    }

    public final func enable(
        formats: [AnyFormat],
        stream: any SampleStream,
        position: CMTime,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId,
        delegate: any SERendererDelegate
    ) throws {
        assert(queue.isCurrent() && state == .disabled)
        SELogger.info(.lifecycle, "\(name) enabled at \(position.seconds)\(joining ? ", joining" : ""), offset \(offset.seconds): \(formats.map(\.description).joined(separator: "; "))")
        self.delegate = delegate
        var stream = stream
        try willChangeStream(oldStream: sampleStream, newStream: &stream)
        state = .enabled
        self.sampleStream = stream
        self.formats = formats
        invalidateRecovery(mediaPeriodId: mediaPeriodId)
        try onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        try replaceStream(formats: formats, stream: stream, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
        try resetPosition(new: startPosition, joining: joining)
    }

    public final func start() throws {
        assert(queue.isCurrent() && state == .enabled)
        SELogger.debug(.lifecycle, "\(name) started")
        state = .started
        try onStarted()
    }

    public final func replaceStream(
        formats: [AnyFormat],
        stream: any SampleStream,
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        invalidateRecovery(mediaPeriodId: mediaPeriodId)
        SELogger.debug(.lifecycle, "\(name) reads a new stream from \(startPosition.seconds), offset \(offset.seconds)")
        var stream = stream
        try willChangeStream(oldStream: sampleStream, newStream: &stream)
        self.sampleStream = stream
        if readingPosition.isPositiveInfinity {
            readingPosition = startPosition
        }
        self.formats = formats
        streamOffset = offset
        try onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
    }

    public final func getStream() -> SampleStream? { sampleStream }
    public final func didReadStreamToEnd() -> Bool { readingPosition.isPositiveInfinity }
    public final func getReadingPosition() -> CMTime { readingPosition }
    open func setStreamFinal() { streamIsFinal = true }
    public final func isCurrentStreamFinal() -> Bool { streamIsFinal }

    public final func getTimeline() -> Timeline { timeline }

    public final func setTimeline(_ timeline: Timeline) {
        guard !self.timeline.equals(to: timeline) else { return }
        self.timeline = timeline
        onTimelineChanged(new: timeline)
    }

    public final func resetPosition(new position: CMTime) throws {
        try resetPosition(new: position, joining: false)
    }

    private func resetPosition(new position: CMTime, joining: Bool) throws {
        SELogger.debug(.lifecycle, "\(name) reset to \(position.seconds)")
        invalidateRecovery()
        streamIsFinal = false
        lastResetPosition = position
        readingPosition = position
        try onPositionReset(position: position, joining: joining)
    }

    open func render(position: CMTime, elapsedRealtime: CMTime) throws {}
    open func isReady() -> Bool { false }
    open func isEnded() -> Bool { true }
    open func hasPresentedOutput() -> Bool { false }
    open func getMediaClock() -> MediaClock? { nil }
    open func getTimebase() -> CMTimebase? { nil }
    open func getRenderSynchronizer() -> (any PlaybackSynchronizer)? { nil }
    open func setPlaybackSpeed(current: Float, target: Float) throws {}
    open func enableRenderStartOfStream() {}

    public final func stop() {
        assert(queue.isCurrent() && state == .started)
        SELogger.debug(.lifecycle, "\(name) stopped")
        state = .enabled
        onStopped()
    }

    public final func disable() {
        assert(queue.isCurrent() && state == .enabled)
        SELogger.info(.lifecycle, "\(name) disabled")
        invalidateRecovery()
        state = .disabled
        // The subclass must still be able to unregister triggers from its old stream.
        onDisabled()
        sampleStream = nil
        formats.removeAll()
        streamIsFinal = false
    }

    public final func reset() {
        assert(queue.isCurrent() && state == .disabled)
        onReset()
    }

    public final func release() {
        assert(queue.isCurrent() && state == .disabled)
        SELogger.debug(.lifecycle, "\(name) released")
        onRelease()
    }

    open func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        .create(formatSupport: .unsupportedType)
    }

    open func supportsMixedMimeTypeAdaptation() throws -> RendererCapabilities.Support.AdaptiveSupport {
        .notSupported
    }

    /// Called when the renderer is enabled. Does nothing by default.
    ///
    /// - Parameters:
    ///   - joining: Whether the renderer is enabled to join a playback that is going on.
    ///   - mayRenderStartOfStream: Whether the renderer may render the start of the stream before it is started.
    open func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {}

    open func willChangeStream(oldStream: SampleStream?, newStream: inout SampleStream) throws {}

    /// Called when the stream of the renderer changes: when it is enabled, after
    /// ``onEnabled(joining:mayRenderStartOfStream:)``, and when the stream is replaced while it is enabled or started.
    /// Does nothing by default.
    ///
    /// - Parameters:
    ///   - formats: The enabled formats.
    ///   - startPosition: The start of the new stream, in renderer time.
    ///   - offset: The offset added to the times of the samples ``readSource(readFlags:)`` reads, so that they
    ///     increase across streams.
    ///   - mediaPeriodId: The period that makes the stream.
    open func onStreamChanged(
        formats: [AnyFormat],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {}

    /// Called when the position is reset: when the renderer is enabled, after
    /// ``onStreamChanged(formats:startPosition:offset:mediaPeriodId:)``, and at a position discontinuity. The stream
    /// then gives samples from a keyframe. Does nothing by default.
    ///
    /// - Parameters:
    ///   - position: The new playback position.
    ///   - joining: Whether the renderer is enabled to join a playback that is going on.
    open func onPositionReset(position: CMTime, joining: Bool) throws {}

    /// Called when the renderer is started. Does nothing by default.
    open func onStarted() throws {}

    /// Called when the renderer is stopped. Does nothing by default.
    open func onStopped() {}

    /// Called when the renderer is disabled. Does nothing by default.
    open func onDisabled() {}

    /// Called when the renderer is reset. Does nothing by default.
    open func onReset() {}

    /// Called when the renderer is released. Does nothing by default.
    open func onRelease() {}

    /// Called when a new timeline is set, which ``getTimeline()`` also returns. Does nothing by default.
    open func onTimelineChanged(new timeline: Timeline) {}

    /// The position the renderer was last enabled or reset at, by ``resetPosition(new:)``.
    public final func getLastResetPosition() -> CMTime { lastResetPosition }
    public final func getStreamOffset() -> CMTime { streamOffset }
    public final func getStreamFormats() -> [AnyFormat] { formats }
    public final func getClock() -> SEClock { clock }
    /// The period that makes the current stream, or `nil` before the renderer was enabled.
    public final func getMediaPeriodId() -> MediaPeriodId? { lock.withLock { recoveryContext.mediaPeriodId } }

    /// Reads from the stream. At its end, the end of stream buffer is only returned once ``setStreamFinal()`` was
    /// called; until then, nothing is read. Called when the renderer is enabled or started.
    public final func readSource(readFlags: ReadFlags = .init()) throws -> SampleStreamReadResult {
        guard let sampleStream else { return .nothingRead }
        let result = try sampleStream.readData(readFlags: readFlags)
        if case let .didReadBuffer(buffer) = result {
            if buffer.flags.contains(.endOfStream) {
                if !readingPosition.isPositiveInfinity {
                    readingPosition = .positiveInfinity
                    delegate?.rendererDidFinishReading(self)
                }
                return streamIsFinal ? .didReadBuffer(buffer) : .nothingRead
            }

            // The output time moves with the stream; it is after the trim at the start, if any.
            try buffer.setOutputPresentationTimeStamp(to: buffer.outputPresentationTimeStamp + streamOffset)
            readingPosition = max(readingPosition, buffer.outputPresentationTimeStamp)
        }

        return result
    }

    /// Skips to the keyframe before `position`, or to the end of the stream if `position` is beyond it, and returns the
    /// number of samples skipped. Called when the renderer is enabled or started.
    public final func skipSource(position: CMTime) throws -> Int {
        try sampleStream?.skipData(position: position - streamOffset) ?? 0
    }

    /// Whether the stream is ready. Called when the renderer is enabled or started.
    public final func isSourceReady() -> Bool {
        didReadStreamToEnd() ? streamIsFinal : sampleStream?.isReady() ?? false
    }

    /// Tells the listener that the capabilities of the renderer changed.
    public final func onRendererCapabilitiesChanged() {
        let listener = lock.withLock { _listener }
        listener?.onRendererCapabilitiesChanged(self)
    }
}
