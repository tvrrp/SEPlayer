//
//  DelayedSampleOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//

import CoreMedia
import SEPlayerCommon

/// Writes the samples of a video stream one behind, so that the duration of each comes from the time of the next.
final class DelayedSampleOutput {
    private struct PendingSample {
        let data: CMBlockBuffer
        /// Without its duration.
        var properties: SampleProperties
    }

    private let trackOutput: TrackOutput

    private var pendingSample: PendingSample?
    private var lastSampleDuration = CMTime.invalid

    init(trackOutput: TrackOutput) {
        self.trackOutput = trackOutput
    }

    /// Holds back a sample, and writes the one before it.
    func output(data: CMBlockBuffer, time: CMTime, decodeTime: CMTime, flags: SampleProperties.Flags) throws {
        let sample = PendingSample(
            data: data,
            properties: SampleProperties(
                timingInfo: CMSampleTimingInfo(
                    duration: .invalid,
                    presentationTimeStamp: time,
                    decodeTimeStamp: decodeTime
                ),
                dataRange: 0 ..< data.dataLength,
                flags: flags
            )
        )
        if let pendingSample {
            try output(pendingSample, followedBy: sample)
        }
        pendingSample = sample
    }

    /// Writes the sample held back, with the duration of the one before it: no sample follows it.
    func flush() throws {
        guard let sample = pendingSample else { return }
        pendingSample = nil
        try output(sample, followedBy: nil)
    }

    /// Drops the sample held back, after a seek or a discontinuity: its data may be cut, and the times that follow
    /// don't give its duration.
    func reset() {
        pendingSample = nil
        lastSampleDuration = .invalid
    }

    private func output(_ sample: PendingSample, followedBy next: PendingSample?) throws {
        let duration = duration(of: sample, followedBy: next)
        lastSampleDuration = duration

        var properties = sample.properties
        properties.timingInfo.duration = duration
        try trackOutput.sampleData(data: sample.data)
        try trackOutput.sampleMetadata(properties)
    }

    private func duration(of sample: PendingSample, followedBy next: PendingSample?) -> CMTime {
        guard let next = next?.properties.timingInfo else {
            return lastSampleDuration
        }
        let sample = sample.properties.timingInfo
        // Samples are written in decode order, so the decode times are the ones that grow.
        let useDecodeTimes = sample.decodeTimeStamp.isNumeric && next.decodeTimeStamp.isNumeric
        let start = useDecodeTimes ? sample.decodeTimeStamp : sample.presentationTimeStamp
        let end = useDecodeTimes ? next.decodeTimeStamp : next.presentationTimeStamp
        guard start.isNumeric, end.isNumeric else { return lastSampleDuration }

        let duration = end - start
        // A jump in the timestamps, or samples that share the time of one PES packet, give a duration that makes no
        // sense: the one before is used instead.
        guard duration > .zero, duration <= Self.longestSampleDuration else {
            return lastSampleDuration
        }
        return duration
    }
}

private extension DelayedSampleOutput {
    /// A sample of a video stream doesn't last longer.
    static let longestSampleDuration = CMTime(value: 1, timescale: 1)
}
