//
//  BaseSERenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.04.2025.
//

import AVFoundation
import Decoder
import SEPlayerCommon

class BaseSERenderer: SERenderer, RendererCapabilitiesResolver {
    final var listener: RendererCapabilitiesListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }
    final weak var delegate: SERendererDelegate?
    var name: String { String(describing: type(of: self)) }
    let trackType: TrackType
    /// The topic this renderer logs its own events under.
    var logTopic: SELogTopic {
        switch trackType {
        case .audio: .audio
        case .video: .video
        case .text: .text
        default: .lifecycle
        }
    }

    let queue: Queue
    private let lock: UnfairLock
    private let clock: SEClock
    private var timebase: CMTimebase?

    private weak var _listener: RendererCapabilitiesListener?
    private var state: SERendererState = .disabled
    private var sampleStream: SampleStream?
    private var formats: [Format] = []

    private var streamIsFinal: Bool = false

    private var lastResetPosition: CMTime = .zero
    private var readingPosition: CMTime = .positiveInfinity
    private var streamOffset: CMTime = .zero
    private var timeline: Timeline
    private var recoveryContext = RendererRecoveryContext(generation: 0, mediaPeriodId: nil)

    init(queue: Queue, trackType: TrackType, clock: SEClock) {
        self.queue = queue
        self.trackType = trackType
        self.clock = clock
        lock = UnfairLock()
        timeline = emptyTimeline
    }

    final func getCapabilities() -> RendererCapabilitiesResolver {
        self
    }

    func handleMessage(_ message: RendererMessage) throws {}

    final func getState() -> SERendererState { state }

    final func getRecoveryContext() -> RendererRecoveryContext { lock.withLock { recoveryContext } }
    var isRecoveringWhileTimelineAdvances: Bool { false }
    func recoverOutput(at position: CMTime, reason: RendererRecoveryReason) throws -> Bool { false }

    private func invalidateRecovery(mediaPeriodId: MediaPeriodId? = nil) {
        lock.withLock {
            recoveryContext = .init(
                generation: recoveryContext.generation &+ 1,
                mediaPeriodId: mediaPeriodId ?? recoveryContext.mediaPeriodId
            )
        }
    }

    /// Unlike a user seek, output recovery retains the final-stream marker and the clock.
    final func rewindSourceForRecovery(to position: CMTime) throws -> Bool {
        guard let sampleStream else { return false }
        guard case .success = try sampleStream.seekWithinBuffer(to: position - streamOffset) else {
            return false
        }
        readingPosition = position
        lastResetPosition = position
        return true
    }

    func enable(
        formats: [Format],
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

    final func start() throws {
        assert(queue.isCurrent() && state == .enabled)
        SELogger.debug(.lifecycle, "\(name) started")
        state = .started
        try onStarted()
    }

    func replaceStream(
        formats: [Format],
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

    final func getStream() -> SampleStream? { sampleStream }
    final func didReadStreamToEnd() -> Bool { return readingPosition.isPositiveInfinity }
    final func getReadingPosition() -> CMTime { return readingPosition }
    func setStreamFinal() { streamIsFinal = true }
    final func isCurrentStreamFinal() -> Bool { streamIsFinal }

    func getTimeline() -> Timeline { timeline }

    final func setTimeline(_ timeline: Timeline) {
        guard !self.timeline.equals(to: timeline) else { return }
        self.timeline = timeline
        onTimelineChanged(new: timeline)
    }

    final func resetPosition(new position: CMTime) throws {
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

    func render(position: CMTime, elapsedRealtime: CMTime) throws {}
    func isReady() -> Bool { false }
    func isEnded() -> Bool { true }
    func hasPresentedOutput() -> Bool { false }
    func getMediaClock() -> MediaClock? { return nil }
    func getTimebase() -> CMTimebase? { return nil }
    func getRenderSynchronizer() -> (any PlaybackSynchronizer)? { nil }
    func setPlaybackSpeed(current: Float, target: Float) throws {}
    func enableRenderStartOfStream() {}

    final func stop() {
        assert(queue.isCurrent() && state == .started)
        SELogger.debug(.lifecycle, "\(name) stopped")
        state = .enabled
        onStopped()
    }

    final func disable() {
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

    final func reset() {
        assert(queue.isCurrent() && state == .disabled)
        onReset()
    }

    final func release() {
        assert(queue.isCurrent() && state == .disabled)
        SELogger.debug(.lifecycle, "\(name) released")
        onRelease()
    }

    func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        .create(formatSupport: .unsupportedType)
    }

    func supportsMixedMimeTypeAdaptation() throws -> RendererCapabilities.Support.AdaptiveSupport {
        .notSupported
    }

    func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {}

    func willChangeStream(oldStream: SampleStream?, newStream: inout SampleStream) throws {}

    func onStreamChanged(
        formats: [Format],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {}

    func onPositionReset(position: CMTime, joining: Bool) throws {}
    func onStarted() throws {}
    func onStopped() {}
    func onDisabled() {}
    func onReset() {}
    func onRelease() {}
    func onTimelineChanged(new timeline: Timeline) {}

    final func getLastResetPosition() -> CMTime { lastResetPosition }
    final func getStreamOffset() -> CMTime { streamOffset }
    final func getStreamFormats() -> [Format] { formats }
    final func getClock() -> SEClock { clock }

    final func readSource(readFlags: ReadFlags = .init()) throws -> SampleStreamReadResult {
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

            try buffer.setOutputPresentationTimeStamp(to: buffer.presentationTimeStamp + streamOffset)
            readingPosition = max(readingPosition, buffer.outputPresentationTimeStamp)
        }

        return result
    }

    final func skipSource(position: CMTime) throws -> Int {
        try sampleStream?.skipData(position: position - streamOffset) ?? 0
    }

    final func isSourceReady() -> Bool {
        didReadStreamToEnd() ? streamIsFinal : sampleStream?.isReady() ?? false
    }

    final func onRendererCapabilitiesChanged() {
        let listener = lock.withLock { _listener }
        listener?.onRendererCapabilitiesChanged(self)
    }
}
