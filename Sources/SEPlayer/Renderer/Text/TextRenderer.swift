//
//  TextRenderer.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.text.TextRenderer
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import Extractor
import SEPlayerCommon

/// A renderer for text.
///
/// This implementation only supports `MimeTypes.applicationSEPlayerCues` samples: subtitles are parsed into cues while
/// they are extracted.
///
/// The player has no render loop, so the renderer wakes itself: the sample stream tells it when data arrives, and
/// timers on the control timebase fire when the cues on screen change and when the next sample is close enough to read.
final class TextRenderer: BaseSERenderer {
    private let output: TextOutput
    private let cueDecoder = CueDecoder()
    private let cueChangeTimer: TimebaseTimer
    private let readAheadTimer: TimebaseTimer

    private var controlTimebase: CMTimebase?
    private var cuesResolver: CuesResolver?
    private var streamFormat: AnyFormat?
    private var sampleStreamToken: QueueTriggerToken?
    private var inputStreamEnded = false
    private var outputStreamEnded = false
    private var lastRendererPosition: CMTime = .invalid
    private var scheduledCueChangeTime: CMTime = .invalid

    init(queue: Queue, clock: SEClock, output: TextOutput) {
        self.output = output
        cueChangeTimer = TimebaseTimer(queue: queue.queue)
        readAheadTimer = TimebaseTimer(queue: queue.queue)

        super.init(queue: queue, trackType: .text, clock: clock)

        cueChangeTimer.setEventHandler { [weak self] in
            self?.renderCues(firedAt: self?.scheduledCueChangeTime ?? .invalid)
        }
        readAheadTimer.setEventHandler { [weak self] in
            self?.renderCues()
        }
    }

    override var name: String { "TextRenderer" }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        if format.sampleMimeType == .applicationSEPlayerCues {
            .create(formatSupport: .handled)
        } else if format.trackType == .text {
            .create(formatSupport: .unsupportedSubtype)
        } else {
            .create(formatSupport: .unsupportedType)
        }
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setTimeSource(source) = message, source?.timebase !== controlTimebase {
            controlTimebase = source?.timebase
            try cueChangeTimer.setTimebase(controlTimebase)
            try readAheadTimer.setTimebase(controlTimebase)
            // Timers set on the old timebase are gone with it.
            renderCues()
        }

        try super.handleMessage(message)
    }

    override func onStreamChanged(
        formats: [AnyFormat],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        let streamFormat = formats[0]
        self.streamFormat = streamFormat

        // Cues are kept in renderer time, so the ones of the previous stream still show until they end.
        switch streamFormat.text?.cueReplacementBehavior ?? .merge {
        case .merge:
            if !(cuesResolver is MergingCuesResolver) { cuesResolver = MergingCuesResolver() }
        case .replace:
            if !(cuesResolver is ReplacingCuesResolver) { cuesResolver = ReplacingCuesResolver() }
        }

        inputStreamEnded = false
        outputStreamEnded = false
        queue.justDispatch { [weak self] in self?.renderCues() }
    }

    override func willChangeStream(oldStream: (any SampleStream)?, newStream: inout any SampleStream) throws {
        removeSampleStreamTrigger(from: oldStream)
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        lastRendererPosition = position
        cuesResolver?.clear()
        clearOutput()
        inputStreamEnded = false
        outputStreamEnded = false
        cancelTimers()

        // The stream is reset after this, so read it once that is done.
        removeSampleStreamTrigger(from: getStream())
        queue.justDispatch { [weak self] in self?.renderCues() }
    }

    override func setStreamFinal() {
        super.setStreamFinal()
        renderCues()
    }

    override func onDisabled() {
        streamFormat = nil
        clearOutput()
        lastRendererPosition = .invalid
        cuesResolver = nil
        cancelTimers()
        removeSampleStreamTrigger(from: getStream())
    }

    override func isEnded() -> Bool {
        outputStreamEnded
    }

    override func isReady() -> Bool {
        guard streamFormat != nil, let cuesResolver else { return true }

        // We don't block playback whilst subtitles are loading.
        if cuesResolver.getNextCueChangeTime(lastRendererPosition) != nil {
            // We have a cue change loaded in the future.
            return true
        }

        // We don't have any future cues, so let's see if there's a loading error, and return ready=false if so.
        do {
            try getStream()?.maybeThrowError()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Rendering

    /// Reads the cues close enough to the current position, and updates the output if the cues on screen change.
    ///
    /// - Parameter fireTime: The time a cue change timer was set to fire at. The timebase may be a little behind it.
    private func renderCues(firedAt fireTime: CMTime = .invalid) {
        assert(queue.isCurrent())
        guard getState() != .disabled, let cuesResolver, !outputStreamEnded else {
            return
        }

        var position = controlTimebase?.time ?? getLastResetPosition()
        if fireTime.isValid {
            position = max(position, fireTime)
        }

        do {
            var outputNeedsUpdating = try readAndDecodeCues(position: position, cuesResolver: cuesResolver)

            // A change since the last pass.
            if let nextCueChangeTime = cuesResolver.getNextCueChangeTime(lastRendererPosition),
               nextCueChangeTime <= position {
                outputNeedsUpdating = true
            }

            if outputNeedsUpdating {
                let cuesAtTime = cuesResolver.getCues(at: position)
                let previousCueChangeTime = cuesResolver.getPreviousCueChangeTime(position)
                SELogger.debug(.text, "\(cuesAtTime.count) cues at \(position.seconds)")
                updateOutput(CueGroup(
                    cues: cuesAtTime,
                    presentationTime: presentationTime(previousCueChangeTime ?? position)
                ))
                if let previousCueChangeTime {
                    cuesResolver.discardCues(before: previousCueChangeTime)
                }
            }
            lastRendererPosition = position

            // Ended once all the cues are read and none changes after the position: the last one has gone.
            if inputStreamEnded, cuesResolver.getNextCueChangeTime(position) == nil {
                outputStreamEnded = true
            }

            if outputStreamEnded {
                cancelTimers()
                delegate?.rendererDidFinishRendering(self)
            } else {
                try scheduleCueChangeTimer(after: position, cuesResolver: cuesResolver)
            }
        } catch {
            delegate?.onRendererError(self, error: createPlaybackError(error))
        }
    }

    /// Reads the samples that start no later than a second after `position`, and adds their cues to `cuesResolver`.
    ///
    /// - Returns: Whether the cues shown at `position` changed.
    private func readAndDecodeCues(position: CMTime, cuesResolver: CuesResolver) throws -> Bool {
        var outputNeedsUpdating = false

        while !inputStreamEnded, let stream = getStream() {
            switch try stream.readData(readFlags: [.peek, .omitSampleData]) {
            case .nothingRead:
                // Nothing to consume yet.
                installSampleStreamTrigger(on: stream)
                return outputNeedsUpdating
            case .didReadFormat:
                // Peeking a format consumes it: the next read returns the sample.
                continue
            case let .didReadBuffer(peekedBuffer):
                if peekedBuffer.flags.contains(.endOfStream) {
                    // Read until the stream is final: replacing the stream, or making it final, wakes the renderer.
                    if case .didReadBuffer = try readSource() {
                        inputStreamEnded = true
                    }
                    return outputNeedsUpdating
                }

                // New buffer available, only consume if close enough to the current position.
                let readTime = peekedBuffer.presentationTimeStamp + getStreamOffset() - Self.maxReadAheadDuration
                if position < readTime {
                    try readAheadTimer.setFireTime(readTime)
                    return outputNeedsUpdating
                }

                guard case let .didReadBuffer(buffer) = try readSource() else {
                    continue
                }
                guard let data = buffer.dataBuffer else { continue }

                let cuesWithTiming: CuesWithTiming
                do {
                    cuesWithTiming = try cueDecoder.decode(startTime: buffer.outputPresentationTimeStamp, data: data)
                } catch {
                    // A broken sample loses its cues, not the playback.
                    SELogger.warning(.text, "Decoding the cues of a sample failed: \(error)")
                    continue
                }

                if try cuesResolver.addCues(cuesWithTiming, currentPosition: position) {
                    outputNeedsUpdating = true
                }
            }
        }

        return outputNeedsUpdating
    }

    private func scheduleCueChangeTimer(after position: CMTime, cuesResolver: CuesResolver) throws {
        scheduledCueChangeTime = cuesResolver.getNextCueChangeTime(position) ?? .invalid
        try cueChangeTimer.setFireTime(scheduledCueChangeTime)
    }

    private func cancelTimers() {
        scheduledCueChangeTime = .invalid
        cueChangeTimer.cancel()
        readAheadTimer.cancel()
    }

    private func installSampleStreamTrigger(on stream: SampleStream) {
        // After the end of the stream there is nothing to wait for: making the stream final or replacing it wakes the
        // renderer.
        guard sampleStreamToken == nil, !didReadStreamToEnd() else { return }

        sampleStreamToken = stream.installTrigger(condition: .whenDataBecomesReady) { [weak self] _ in
            self?.queue.justDispatch { [weak self] in
                guard let self else { return }
                removeSampleStreamTrigger(from: getStream())
                renderCues()
            }
        }
    }

    private func removeSampleStreamTrigger(from stream: SampleStream?) {
        guard let sampleStreamToken else { return }
        self.sampleStreamToken = nil
        stream?.removeTrigger(sampleStreamToken)
    }

    // MARK: - Output

    private func updateOutput(_ cueGroup: CueGroup) {
        let output = output
        DispatchQueue.main.async {
            output.onCues(cueGroup)
        }
    }

    private func clearOutput() {
        let time = lastRendererPosition.isValid ? presentationTime(lastRendererPosition) : .zero
        updateOutput(CueGroup(cues: [], presentationTime: time))
    }

    private func presentationTime(_ position: CMTime) -> CMTime {
        position - getStreamOffset()
    }

    private func createPlaybackError(_ error: Error) -> SEPlaybackError {
        .createForRenderer(
            error,
            rendererName: name,
            rendererIndex: 0,
            trackType: trackType,
            format: streamFormat,
            mediaPeriodId: getRecoveryContext().mediaPeriodId ?? .init()
        )
    }
}

private extension TextRenderer {
    static let maxReadAheadDuration = CMTime(value: 1, timescale: 1)
}
