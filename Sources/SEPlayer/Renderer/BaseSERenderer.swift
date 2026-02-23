//
//  BaseSERenderer2.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 21.04.2025.
//

import CoreMedia

class BaseSERenderer: SERenderer, RendererCapabilitiesResolver {
    final var listener: RendererCapabilitiesListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }
    var name: String { String(describing: self) }
    let trackType: TrackType

    private let queue: Queue
    private let lock: UnfairLock
    private let clock: SEClock

    private weak var _listener: RendererCapabilitiesListener?
    private var state: SERendererState = .disabled
    private var sampleStream: SampleStream?
    private var formats: [Format] = []

    private var streamIsFinal: Bool = false

    private var lastResetPosition: Int64 = .zero
    private var readingPosition: Int64 = .endOfSource
    private var streamOffset: Int64 = .zero
    private var timeline: Timeline

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

    final func enable(
        formats: [Format],
        stream: SampleStream,
        position: Int64,
        joining: Bool,
        mayRenderStartOfStream: Bool,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {
        assert(queue.isCurrent() && state == .disabled)
        state = .enabled
        self.sampleStream = stream
        self.formats = formats
        try! onEnabled(joining: joining, mayRenderStartOfStream: mayRenderStartOfStream)
        try! replaceStream(formats: formats, stream: stream, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
        try! resetPosition(new: startPosition, joining: joining)
    }

    final func start() throws {
        assert(queue.isCurrent() && state == .enabled)
        state = .started
        try! onStarted()
    }

    final func replaceStream(
        formats: [Format],
        stream: SampleStream,
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {
        self.sampleStream = stream
        if readingPosition == .endOfSource {
            readingPosition = startPosition
        }
        self.formats = formats
        streamOffset = offset
        try! onStreamChanged(formats: formats, startPosition: startPosition, offset: offset, mediaPeriodId: mediaPeriodId)
    }

    final func getStream() -> SampleStream? { sampleStream }
    final func didReadStreamToEnd() -> Bool { return readingPosition == .endOfSource }
    final func getReadingPosition() -> Int64 { return readingPosition }
    final func setStreamFinal() { streamIsFinal = true }
    final func isCurrentStreamFinal() -> Bool { streamIsFinal }

    func getTimeline() -> Timeline { timeline }

    final func setTimeline(_ timeline: Timeline) {
        guard !self.timeline.equals(to: timeline) else { return }
        self.timeline = timeline
        onTimelineChanged(new: timeline)
    }

    final func resetPosition(new position: Int64) throws {
        try! resetPosition(new: position, joining: false)
    }

    private func resetPosition(new position: Int64, joining: Bool) throws {
        streamIsFinal = false
        lastResetPosition = position
        readingPosition = position
        try! onPositionReset(position: position, joining: joining)
    }

    func render(position: Int64, elapsedRealtime: Int64) throws {}
    func isReady() -> Bool { false }
    func isEnded() -> Bool { true }
    func getMediaClock() -> MediaClock? { return nil }
    func getTimebase() -> CMTimebase? { return nil }
    func setPlaybackSpeed(current: Float, target: Float) throws {}
    func enableRenderStartOfStream() {}

    final func stop() {
        assert(queue.isCurrent() && state == .started)
        state = .enabled
        onStopped()
    }

    final func disable() {
        assert(queue.isCurrent() && state == .enabled)
        state = .disabled
        sampleStream = nil
        formats.removeAll()
        streamIsFinal = false
        onDisabled()
    }

    final func reset() {
        assert(queue.isCurrent() && state == .disabled)
        onReset()
    }

    final func release() {
        assert(queue.isCurrent() && state == .disabled)
        onRelease()
    }

    func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        .create(formatSupport: .unsupportedType)
    }

    func supportsMixedMimeTypeAdaptation() throws -> RendererCapabilities.Support.AdaptiveSupport {
        .notSupported
    }

    func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {}

    func onStreamChanged(
        formats: [Format],
        startPosition: Int64,
        offset: Int64,
        mediaPeriodId: MediaPeriodId
    ) throws {}

    func onPositionReset(position: Int64, joining: Bool) throws {}
    func onStarted() throws {}
    func onStopped() {}
    func onDisabled() {}
    func onReset() {}
    func onRelease() {}
    func onTimelineChanged(new timeline: Timeline) {}

    final func getLastResetPosition() -> Int64 { lastResetPosition }
    final func getStreamOffset() -> Int64 { streamOffset }
    final func getStreamFormats() -> [Format] { formats }
    final func getClock() -> SEClock { clock }

    final func readSource(to buffer: DecoderInputBuffer, readFlags: ReadFlags = .init()) throws -> SampleStreamReadResult {
        guard let sampleStream else { return .nothingRead }

        let result = try sampleStream.readData(to: buffer, readFlags: readFlags)
        if case .didReadBuffer = result {
            if buffer.flags.contains(.endOfStream) {
                readingPosition = .endOfSource
                return streamIsFinal ? .didReadBuffer : .nothingRead
            }
            buffer.timeUs += streamOffset
            readingPosition = max(readingPosition, buffer.timeUs)
        }

        return result
    }

    final func skipSource(position: Int64) -> Int {
        sampleStream?.skipData(position: position - streamOffset) ?? 0
    }

    final func isSourceReady() -> Bool {
        didReadStreamToEnd() ? streamIsFinal : sampleStream?.isReady() ?? false
    }

    final func onRendererCapabilitiesChanged() {
        let listener = lock.withLock { _listener }
        listener?.onRendererCapabilitiesChanged(self)
    }
}
