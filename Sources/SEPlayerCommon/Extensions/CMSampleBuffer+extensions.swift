//
//  CMSampleBuffer+extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia

public extension CMSampleBuffer {
    var flags: SampleFlags {
        get { getFlags() }
        set { attach(flags: newValue) }
    }

    /// A buffer without samples that tells the consumer the media ended.
    static func createEndOfStream() throws(SampleBufferError) -> CMSampleBuffer {
        try marker(with: [.permanentEmptyMedia: true])
    }

    /// A buffer without samples that carries `attachments` to the consumer, such as an instruction to drain.
    static func marker(
        with attachments: [SampleBufferAttachments.Key: Any],
        sampleTiming: CMSampleTimingInfo? = nil,
        mode: SampleBufferAttachments.Mode = .shouldPropagate
    ) throws(SampleBufferError) -> CMSampleBuffer {
        let buffer = try CMSampleBuffer(
            dataBuffer: nil,
            formatDescription: nil,
            numSamples: 0,
            sampleTimings: sampleTiming.map { [$0] } ?? [],
            sampleSizes: []
        )
        buffer.bufferAttachments.merge(attachments, mode: mode)
        return buffer
    }

    private func getFlags() -> SampleFlags {
        // Read on every sample on its way to the outputs: the values are compared as Core Foundation Booleans, not
        // bridged to Swift.
        var flags = SampleFlags()

        if CMSampleBufferGetNumSamples(self) > 0 {
            let sample = perSampleAttachments[0]
            if sample.bool(for: .notSync) == false {
                flags.insert(.keyframe)
            }
            if sample.bool(for: .dependsOnOthers) == false {
                flags.insert(.notDependedOn)
            }
        }

        let attachments = bufferAttachments
        if attachments.bool(for: .firstSample) == true {
            flags.insert(.firstSample)
        }

        if attachments.bool(for: .lastSample) == true {
            flags.insert(.lastSample)
        }

        if attachments.bool(for: .permanentEmptyMedia) == true {
            flags.insert(.endOfStream)
        }

        return flags
    }

    private func attach(flags: SampleFlags) {
        if !perSampleAttachments.isEmpty {
            let sample = perSampleAttachments[0]
            sample[.notSync] = !flags.contains(.keyframe)
            if flags.contains(.notDependedOn) {
                sample[.isDependedOnByOthers] = false
            }
        }

        if flags.contains(.firstSample) {
            bufferAttachments[.firstSample] = true
        }

        if flags.contains(.lastSample) {
            bufferAttachments[.lastSample] = true
        }

        if flags.contains(.endOfStream) {
            bufferAttachments[.permanentEmptyMedia] = true
        }
    }
}

private extension SampleBufferAttachments.Key {
    static let firstSample = Self(rawValue: "com.seplayer.firstSampleKey" as CFString)
    static let lastSample = Self(rawValue: "com.seplayer.lastSampleKey" as CFString)
}
