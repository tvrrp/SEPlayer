//
//  FakeRenderer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.11.2025.
//

import CoreMedia
import Testing
@testable import SEPlayer

/// Reads samples like a real renderer and counts them instead of showing them.
///
/// The player has no timer: like `AVFBaseRenderer`, the renderer reads when something wakes
/// it — a new stream, a position reset, data arriving in the stream, or the time reaching the
/// next sample — and tells the player when it becomes ready, stalls or ends.
class FakeRenderer: BaseSERenderer {
    var _isEnded = false
    var isReleased = false
    var positionResetCount = 0
    var sampleBufferReadCount = 0
    var enabledCount = 0
    var resetCount = 0

    private let sourceReadahead = CMTime.from(microseconds: 250_000)
    private let readAheadTimer: DispatchSourceTimer

    private var playbackPosition = CMTime.zero
    private var lastSamplePosition = CMTime.negativeInfinity
    private var pendingBuffer: CMSampleBuffer?
    private var controlTimebase: CMTimebase?
    private var streamToken: QueueTriggerToken?
    private var wasReady = false
    private(set) var formatsRead = [Format]()

    override init(queue: Queue = playerSyncQueue, trackType: TrackType, clock: SEClock) {
        readAheadTimer = DispatchSource.makeTimerSource(queue: queue.queue)
        super.init(queue: queue, trackType: trackType, clock: clock)
        readAheadTimer.setEventHandler { [weak self] in self?.readStream() }
        readAheadTimer.activate()
    }

    deinit {
        readAheadTimer.cancel()
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setTimeSource(source) = message, source?.timebase !== controlTimebase {
            try controlTimebase?.removeTimer(readAheadTimer)
            controlTimebase = source?.timebase
            try controlTimebase?.addTimer(readAheadTimer)
        }
        try super.handleMessage(message)
    }

    override func onStreamChanged(
        formats: [Format],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        removeStreamTrigger()
        queue.justDispatch { [weak self] in self?.readStream() }
    }

    override func willChangeStream(oldStream: SampleStream?, newStream: inout SampleStream) throws {
        removeStreamTrigger(from: oldStream)
    }

    override func setStreamFinal() {
        super.setStreamFinal()
        // The end of the stream is only read once the stream is final.
        queue.justDispatch { [weak self] in self?.readStream() }
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        defer { queue.justDispatch { [weak self] in self?.readStream() } }
        if playbackPosition == position && lastSamplePosition == .negativeInfinity && !_isEnded {
            // Nothing change, ignore reset operation.
            return
        }

        playbackPosition = position
        lastSamplePosition = .negativeInfinity
        pendingBuffer = nil
        positionResetCount += 1
        _isEnded = false
        wasReady = false
        disarmTimers()
    }

    override func render(position: CMTime, elapsedRealtime: CMTime) throws {
        playbackPosition = position
        try readStreamThrowing()
    }

    override func onEnabled(joining: Bool, mayRenderStartOfStream: Bool) throws {
        enabledCount += 1
    }

    override func onDisabled() {
        removeStreamTrigger()
        disarmTimers()
    }

    override func onReset() {
        resetCount += 1
    }

    override func isReady() -> Bool {
        lastSamplePosition >= playbackPosition || pendingBuffer != nil || isSourceReady()
    }

    override func isEnded() -> Bool { _isEnded }

    override func supportsFormat(_ format: Format) throws -> RendererCapabilities.Support {
        if format.sampleMimeType?.trackType == trackType {
            return .create(formatSupport: .handled, adaptiveSupport: .seamless, tunnelingSupport: .notSupported)
        } else {
            return .create(formatSupport: .unsupportedType)
        }
    }

    func onFormatChange(format: Format) {}

    func shouldProcessBuffer(bufferTime: CMTime, playbackPosition: CMTime) throws -> Bool {
        bufferTime < playbackPosition + sourceReadahead
    }

    override func onRelease() {
        isReleased = true
    }

    // MARK: - Reading

    private func readStream() {
        do {
            try readStreamThrowing()
        } catch {
            Issue.record(error, "FakeRenderer failed to read its stream")
        }
    }

    private func readStreamThrowing() throws {
        assert(queue.isCurrent())
        guard [.enabled, .started].contains(getState()), !_isEnded else {
            return
        }

        // Between `render` calls the time comes from the timebase the player plays on.
        if let controlTimebase, getState() == .started {
            playbackPosition = max(playbackPosition, controlTimebase.time)
        }

        defer { reportReadinessChange() }
        while true {
            if let pendingBuffer {
                let bufferTime = pendingBuffer.outputPresentationTimeStamp
                guard try shouldProcessBuffer(bufferTime: bufferTime, playbackPosition: playbackPosition) else {
                    // Read on once the buffer comes within the read-ahead.
                    try controlTimebase?.setTimerNextFireTime(readAheadTimer, fireTime: bufferTime - sourceReadahead)
                    return
                }

                lastSamplePosition = bufferTime
                sampleBufferReadCount += 1
                self.pendingBuffer = nil
                continue
            }

            switch try readSource() {
            case let .didReadFormat(format):
                guard format.sampleMimeType?.trackType == trackType else {
                    throw ErrorBuilder(errorDescription: "wrong track type")
                }
                formatsRead.append(format)
                onFormatChange(format: format)
            case let .didReadBuffer(buffer):
                if buffer.flags.contains(.endOfStream) {
                    _isEnded = true
                    delegate?.rendererDidFinishRendering(self)
                    return
                }
                pendingBuffer = buffer
            case .nothingRead:
                installStreamTrigger()
                return
            }
        }
    }

    private func disarmTimers() {
        try? controlTimebase?.setTimerNextFireTime(readAheadTimer, fireTime: .invalid)
    }

    private func reportReadinessChange() {
        let isReady = isReady()
        guard isReady != wasReady else { return }
        wasReady = isReady
        if isReady {
            delegate?.rendererFinishedPreroll(self)
        } else {
            delegate?.rendererPipelineStalled(self)
        }
    }

    private func installStreamTrigger() {
        // After the end of the stream only marking it final or replacing it wakes the renderer.
        guard streamToken == nil, !didReadStreamToEnd(), let stream = getStream() else {
            return
        }
        streamToken = stream.installTrigger(condition: .whenDataBecomesReady) { [weak self] _ in
            guard let self else { return }
            queue.justDispatch {
                self.streamToken = nil
                self.readStream()
            }
        }
    }

    private func removeStreamTrigger(from stream: SampleStream? = nil) {
        guard let streamToken else { return }
        self.streamToken = nil
        (stream ?? getStream())?.removeTrigger(streamToken)
    }
}
