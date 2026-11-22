//
//  AudioPacketBatch.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 23.10.2026.
//

import CoreMedia
import SEPlayerCommon

/// Compressed audio packets that follow each other, joined into one sample buffer for the output.
///
/// The output passes every buffer it takes to another process, and a packet lasts some 20 ms: a buffer per packet is
/// about fifty of those a second. A batch holds a fifth of a second.
///
/// Packets that only prime the decoder start a batch with the first packet played: the output drops a buffer with
/// nothing to play, and the decoder would then miss them.
struct AudioPacketBatch {
    /// How much audio a batch holds at most.
    static let maximumDuration = CMTime(value: 1, timescale: 5)
    /// How many packets a batch holds at most, for packets far shorter than usual.
    static let maximumPacketCount = 64
    /// How far apart packets may be and still follow each other: the container's clock restarts with each of its
    /// packets, rounded to its own timescale.
    private static let continuityTolerance = CMTime(value: 1, timescale: 1000)

    private static let batchAttachments: Set<SampleBufferAttachments.Key> = [
        .firstSample, .lastSample, .trimDurationAtStart, .trimDurationAtEnd,
    ]

    private var buffers: [CMSampleBuffer]
    private var duration: CMTime
    /// Where the next packet starts, in the stream's time.
    private var end: CMTime
    /// What isn't played at the start: the packets that only prime the decoder and the start of the first one played.
    private var trimmedStart: CMTime
    /// Whether a packet of the batch is played. A packet trimmed at its start can't follow one.
    private(set) var hasPlayableAudio: Bool
    private var trimmedEnd: CMTime

    /// A batch starting with `buffer`, or `nil` when other packets can't join it.
    init?(_ buffer: CMSampleBuffer) {
        guard let trim = Self.startTrim(of: buffer) else { return nil }
        buffers = [buffer]
        duration = buffer.duration
        end = buffer.presentationTimeStamp + buffer.duration
        trimmedStart = trim
        trimmedEnd = buffer.bufferAttachments.time(for: .trimDurationAtEnd) ?? .zero
        hasPlayableAudio = trim + trimmedEnd < buffer.duration
    }

    /// Whether `buffer` goes at the end: of the same format, right after the last packet, and with room for it.
    func canAppend(_ buffer: CMSampleBuffer) -> Bool {
        guard buffers.count < Self.maximumPacketCount,
              duration + buffer.duration <= Self.maximumDuration else {
            return false
        }
        // A packet trimmed at its end, or the last of its stream, ends the batch.
        guard trimmedEnd == .zero, buffers.last?.flags.contains(.lastSample) != true else {
            return false
        }
        // A packet trimmed at its start can't follow one that plays, and the first of a stream follows none.
        guard let trim = Self.startTrim(of: buffer), trim == .zero || !hasPlayableAudio,
              !buffer.flags.contains(.firstSample) else {
            return false
        }
        guard let format = buffers[0].formatDescription, let newFormat = buffer.formatDescription,
              format === newFormat || CFEqual(format, newFormat) else {
            return false
        }
        let gap = buffer.presentationTimeStamp - end
        return gap.isNumeric && CMTimeAbsoluteValue(gap) <= Self.continuityTolerance
    }

    mutating func append(_ buffer: CMSampleBuffer) {
        let trim = buffer.bufferAttachments.time(for: .trimDurationAtStart) ?? .zero
        buffers.append(buffer)
        duration = duration + buffer.duration
        end = buffer.presentationTimeStamp + buffer.duration
        trimmedStart = trimmedStart + trim
        trimmedEnd = buffer.bufferAttachments.time(for: .trimDurationAtEnd) ?? .zero
        hasPlayableAudio = hasPlayableAudio || trim + trimmedEnd < buffer.duration
    }

    /// The packets in one sample buffer, at the output time of the first.
    ///
    /// Per-packet attachments keep their indices. Trim durations apply to the entire batch.
    func makeSampleBuffer() throws -> CMSampleBuffer {
        guard buffers.count > 1 else { return buffers[0] }

        let dataBuffer = try CMBlockBuffer(capacity: buffers.count)
        var timings: [CMSampleTimingInfo] = []
        var sizes: [Int] = []
        timings.reserveCapacity(buffers.count)
        sizes.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.dataBuffer else {
                throw SampleBufferError.requiredParameterMissing
            }
            let size = buffer.totalSampleSize
            try dataBuffer.append(bufferReference: data, range: 0 ..< size)
            timings.append(CMSampleTimingInfo(
                duration: buffer.duration,
                presentationTimeStamp: buffer.presentationTimeStamp,
                decodeTimeStamp: buffer.decodeTimeStamp
            ))
            sizes.append(size)
        }

        let sampleBuffer = try CMSampleBuffer(
            dataBuffer: dataBuffer,
            formatDescription: buffers[0].formatDescription,
            numSamples: buffers.count,
            sampleTimings: timings,
            sampleSizes: sizes
        )
        for (index, buffer) in buffers.enumerated() {
            sampleBuffer.perSampleAttachments[index] = buffer.perSampleAttachments[0]
        }
        // The flags of the first packet, and the end of the stream when the last packet ends it.
        var flags = buffers[0].flags
        if buffers.last?.flags.contains(.lastSample) == true {
            flags.insert(.lastSample)
        }
        sampleBuffer.flags = flags
        sampleBuffer.setTrim(
            atStart: min(trimmedStart, duration),
            atEnd: min(trimmedEnd, duration - trimmedStart)
        )
        // The output starts after everything trimmed at the start, of which the first packet's output time has its own
        // trim only.
        let firstTrim = buffers[0].bufferAttachments.time(for: .trimDurationAtStart) ?? .zero
        try sampleBuffer.setOutputPresentationTimeStamp(
            to: buffers[0].outputPresentationTimeStamp + (trimmedStart - min(firstTrim, buffers[0].duration))
        )
        return sampleBuffer
    }

    /// What a packet that can join a batch trims at its start, or `nil` when it can't join: one packet of known length
    /// with its data, a sync sample, and nothing else for the output to do but play it or trim its start.
    private static func startTrim(of buffer: CMSampleBuffer) -> CMTime? {
        guard buffer.numSamples == 1, buffer.dataBuffer != nil, buffer.dataReadiness == .ready else {
            return nil
        }
        guard buffer.duration.isNumeric, buffer.duration > .zero else {
            return nil
        }
        let flags = buffer.flags
        guard flags.contains(.keyframe), !flags.contains(.endOfStream) else {
            return nil
        }

        // Anything else attached is for the output to act on at this packet.
        let attachments = buffer.bufferAttachments
        guard attachments.all(.shouldNotPropagate).isEmpty else {
            return nil
        }
        guard attachments.all(.shouldPropagate).keys.allSatisfy(batchAttachments.contains) else {
            return nil
        }

        let trim = attachments.time(for: .trimDurationAtStart) ?? .zero
        return min(trim, buffer.duration)
    }
}
