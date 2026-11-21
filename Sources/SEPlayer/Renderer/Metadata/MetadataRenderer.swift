//
//  MetadataRenderer.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import Extractor
import SEPlayerCommon

/// A renderer for timed metadata: it decodes the samples of a metadata track and outputs them at their times.
///
/// The player has no render loop, so the renderer wakes itself: the sample stream tells it when data arrives, and a
/// timer on the control timebase fires when the next metadata is due.
final class MetadataRenderer: BaseSERenderer {
    private struct PendingMetadata {
        /// In renderer time.
        let time: CMTime
        let metadata: Metadata
    }

    private let output: MetadataOutput
    private let decoderFactory: MetadataDecoderFactory
    private let outputTimer: TimebaseTimer

    private var controlTimebase: CMTimebase?
    private var decoder: (any MetadataDecoder)?
    private var streamFormat: AnyFormat?
    private var pendingMetadata: [PendingMetadata] = []
    private var sampleStreamToken: QueueTriggerToken?
    private var inputStreamEnded = false
    private var outputStreamEnded = false

    init(
        queue: Queue,
        clock: SEClock,
        output: MetadataOutput,
        decoderFactory: MetadataDecoderFactory = DefaultMetadataDecoderFactory()
    ) {
        self.output = output
        self.decoderFactory = decoderFactory
        outputTimer = TimebaseTimer(queue: queue.queue)

        super.init(queue: queue, trackType: .metadata, clock: clock)

        outputTimer.setEventHandler { [weak self] in
            self?.renderMetadata()
        }
    }

    override var name: String { "MetadataRenderer" }

    override func supportsFormat(_ format: AnyFormat) throws -> RendererCapabilities.Support {
        if let metadata = format.timedMetadata, decoderFactory.supportsFormat(metadata) {
            .create(formatSupport: .handled)
        } else if format.trackType == .metadata {
            .create(formatSupport: .unsupportedSubtype)
        } else {
            .create(formatSupport: .unsupportedType)
        }
    }

    override func handleMessage(_ message: RendererMessage) throws {
        if case let .setTimeSource(source) = message, source?.timebase !== controlTimebase {
            controlTimebase = source?.timebase
            try outputTimer.setTimebase(controlTimebase)
            // A timer set on the old timebase is gone with it.
            renderMetadata()
        }

        try super.handleMessage(message)
    }

    override func onStreamChanged(
        formats: [AnyFormat],
        startPosition: CMTime,
        offset: CMTime,
        mediaPeriodId: MediaPeriodId
    ) throws {
        streamFormat = formats[0]
        decoder = formats[0].timedMetadata.flatMap { decoderFactory.createDecoder(for: $0) }
        inputStreamEnded = false
        outputStreamEnded = false
        queue.justDispatch { [weak self] in self?.renderMetadata() }
    }

    override func willChangeStream(oldStream: (any SampleStream)?, newStream: inout any SampleStream) throws {
        removeSampleStreamTrigger(from: oldStream)
    }

    override func onPositionReset(position: CMTime, joining: Bool) throws {
        pendingMetadata.removeAll()
        inputStreamEnded = false
        outputStreamEnded = false
        outputTimer.cancel()

        // The stream is reset after this, so read it once that is done.
        removeSampleStreamTrigger(from: getStream())
        queue.justDispatch { [weak self] in self?.renderMetadata() }
    }

    override func setStreamFinal() {
        super.setStreamFinal()
        renderMetadata()
    }

    override func onDisabled() {
        streamFormat = nil
        decoder = nil
        pendingMetadata.removeAll()
        outputTimer.cancel()
        removeSampleStreamTrigger(from: getStream())
    }

    override func isEnded() -> Bool { outputStreamEnded }

    /// Metadata never holds playback.
    override func isReady() -> Bool { true }

    // MARK: - Rendering

    /// Reads and decodes the samples up to a little after the current position, and outputs the metadata that is due.
    private func renderMetadata() {
        assert(queue.isCurrent())
        guard getState() != .disabled, streamFormat != nil, !outputStreamEnded else { return }

        let position = controlTimebase?.time ?? getLastResetPosition()
        do {
            try readMetadata(upTo: position + Self.maxReadAheadDuration)
            outputDueMetadata(at: position)

            if inputStreamEnded, pendingMetadata.isEmpty {
                outputStreamEnded = true
                outputTimer.cancel()
                delegate?.rendererDidFinishRendering(self)
            } else if let next = pendingMetadata.first {
                try outputTimer.setFireTime(next.time)
            }
        } catch {
            delegate?.onRendererError(self, error: createPlaybackError(error))
        }
    }

    /// Reads the samples that start no later than `limit`, decoding each into ``pendingMetadata``.
    private func readMetadata(upTo limit: CMTime) throws {
        while !inputStreamEnded, let stream = getStream() {
            switch try stream.readData(readFlags: [.peek, .omitSampleData]) {
            case .nothingRead:
                installSampleStreamTrigger(on: stream)
                return
            case .didReadFormat:
                // Peeking a format consumes it: the next read returns the sample.
                continue
            case let .didReadBuffer(peekedBuffer):
                if peekedBuffer.flags.contains(.endOfStream) {
                    // Read until the stream is final: replacing the stream, or making it final, wakes the renderer.
                    if case .didReadBuffer = try readSource() {
                        inputStreamEnded = true
                    }
                    return
                }

                let sampleTime = peekedBuffer.presentationTimeStamp + getStreamOffset()
                if sampleTime > limit {
                    // Read again when it is close enough.
                    try outputTimer.setFireTime(sampleTime - Self.maxReadAheadDuration)
                    return
                }

                guard case let .didReadBuffer(buffer) = try readSource() else { continue }
                guard let data = buffer.dataBuffer, let metadata = decode(data) else { continue }
                insert(PendingMetadata(time: buffer.outputPresentationTimeStamp, metadata: metadata))
            }
        }
    }

    private func decode(_ data: CMBlockBuffer) -> Metadata? {
        guard let decoder else { return nil }
        guard let metadata = decoder.decode(BlockBufferReader(data)) else {
            SELogger.warning(.metadata, "A metadata sample has nothing that can be read")
            return nil
        }
        let entries = metadata.entries.flatMap(decodeWrappedMetadata)
        return entries.isEmpty ? nil : Metadata(entries: entries)
    }

    /// The entries of the metadata that `entry` wraps, as ID3 tags in event messages, or `entry` itself.
    private func decodeWrappedMetadata(_ entry: any Metadata.Entry) -> [any Metadata.Entry] {
        guard let format = entry.wrappedMetadataFormat,
              let data = entry.wrappedMetadataData,
              let reader = try? BlockBufferReader(bytes: data),
              let decoder = decoderFactory.createDecoder(for: format),
              let wrapped = decoder.decode(reader) else {
            return [entry]
        }
        return wrapped.entries.flatMap(decodeWrappedMetadata)
    }

    private func insert(_ metadata: PendingMetadata) {
        let index = pendingMetadata.firstIndex { $0.time > metadata.time } ?? pendingMetadata.endIndex
        pendingMetadata.insert(metadata, at: index)
    }

    private func outputDueMetadata(at position: CMTime) {
        while let next = pendingMetadata.first, next.time <= position {
            pendingMetadata.removeFirst()
            let metadata = next.metadata.withPresentationTime(next.time - getStreamOffset())
            SELogger.debug(.metadata, "Metadata at \(metadata.presentationTime.seconds): \(metadata)")
            let output = output
            DispatchQueue.main.async {
                output.onMetadata(metadata)
            }
        }
    }

    private func installSampleStreamTrigger(on stream: SampleStream) {
        // After the end of the stream there is nothing to wait for: making the stream final or replacing it wakes the
        // renderer.
        guard sampleStreamToken == nil, !didReadStreamToEnd() else { return }

        sampleStreamToken = stream.installTrigger(condition: .whenDataBecomesReady) { [weak self] _ in
            self?.queue.justDispatch { [weak self] in
                guard let self else { return }
                removeSampleStreamTrigger(from: getStream())
                renderMetadata()
            }
        }
    }

    private func removeSampleStreamTrigger(from stream: SampleStream?) {
        guard let sampleStreamToken else { return }
        self.sampleStreamToken = nil
        stream?.removeTrigger(sampleStreamToken)
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

private extension MetadataRenderer {
    /// How long before its time a sample is read and decoded.
    static let maxReadAheadDuration = CMTime(value: 1, timescale: 2)
}
