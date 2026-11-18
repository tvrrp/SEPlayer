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
struct AudioPacketBatch {
    /// How much audio a batch holds at most.
    static let maximumDuration = CMTime(value: 1, timescale: 5)
    /// How many packets a batch holds at most, for packets far shorter than usual.
    static let maximumPacketCount = 64
    /// How far apart packets may be and still follow each other: the container's clock restarts with each of its
    /// packets, rounded to its own timescale.
    private static let continuityTolerance = CMTime(value: 1, timescale: 1000)

    private var buffers: [CMSampleBuffer]
    private var duration: CMTime
    /// Where the next packet starts, in the stream's time.
    private var end: CMTime

    /// A batch starting with `buffer`, or `nil` when other packets can't join it.
    init?(_ buffer: CMSampleBuffer) {
        guard Self.canJoin(buffer) else { return nil }
        buffers = [buffer]
        duration = buffer.duration
        end = buffer.presentationTimeStamp + buffer.duration
    }

    /// Whether `buffer` goes at the end: of the same format, right after the last packet, and with room for it.
    func canAppend(_ buffer: CMSampleBuffer) -> Bool {
        guard buffers.count < Self.maximumPacketCount,
              Self.canJoin(buffer),
              duration + buffer.duration <= Self.maximumDuration,
              let format = buffers[0].formatDescription, let newFormat = buffer.formatDescription,
              format === newFormat || CFEqual(format, newFormat) else {
            return false
        }
        let gap = buffer.presentationTimeStamp - end
        return gap.isNumeric && CMTimeAbsoluteValue(gap) <= Self.continuityTolerance
    }

    mutating func append(_ buffer: CMSampleBuffer) {
        buffers.append(buffer)
        duration = duration + buffer.duration
        end = buffer.presentationTimeStamp + buffer.duration
    }

    /// The packets in one sample buffer, at the output time of the first.
    ///
    /// The buffer has no attachments: every packet is a sync sample, which is what none means.
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
        try sampleBuffer.setOutputPresentationTimeStamp(to: buffers[0].outputPresentationTimeStamp)
        return sampleBuffer
    }

    /// One packet of known length with its data, a sync sample, and nothing for the output to do but play it.
    private static func canJoin(_ buffer: CMSampleBuffer) -> Bool {
        guard buffer.numSamples == 1, buffer.dataBuffer != nil, CMSampleBufferDataIsReady(buffer),
              buffer.duration.isNumeric, buffer.duration > .zero,
              buffer.flags == .keyframe else {
            return false
        }
        let attachments = buffer.bufferAttachments
        return attachments[.trimDurationAtStart] == nil && attachments[.trimDurationAtEnd] == nil
    }
}
