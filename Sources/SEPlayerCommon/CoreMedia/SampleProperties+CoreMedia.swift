//
//  SampleProperties+CoreMedia.swift
//  SEPlayer
//

import CoreMedia

public extension _CoreMediaInitializable where Self == CMSampleBuffer {
    /// A buffer of one sample, with everything `properties` tells about it attached.
    init(
        dataBuffer: CMBlockBuffer?,
        formatDescription: CMFormatDescription?,
        properties: SampleProperties
    ) throws(SampleBufferError) {
        try self.init(
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            numSamples: 1,
            sampleTimings: [properties.timingInfo],
            sampleSizes: [properties.dataRange.count]
        )
        let buffer: CMSampleBuffer = self
        buffer.flags = properties.flags
        if !properties.attributes.isEmpty {
            buffer.attach(properties.attributes)
        }
    }
}

public extension CMSampleBuffer {
    /// The flags of the first sample and of the buffer.
    var flags: SEPlayerCommon.SampleProperties.Flags {
        get {
            // Read on every sample on its way to the outputs: the values are compared as Core Foundation Booleans,
            // not bridged to Swift.
            var flags = SEPlayerCommon.SampleProperties.Flags()
            if CMSampleBufferGetNumSamples(self) > 0 {
                let sample = perSampleAttachments[0]
                for (flag, key, value) in Self.sampleFlagKeys where sample.bool(for: key) == value {
                    flags.insert(flag)
                }
            }
            let attachments = bufferAttachments
            for (flag, key) in Self.bufferFlagKeys where attachments.bool(for: key) == true {
                flags.insert(flag)
            }
            return flags
        }
        set {
            if CMSampleBufferGetNumSamples(self) > 0 {
                let sample = perSampleAttachments[0]
                sample[.notSync] = !newValue.contains(.keyframe)
                for (flag, key, value) in Self.sampleFlagKeys where key != .notSync {
                    sample[key] = newValue.contains(flag) ? value : nil
                }
            }
            let attachments = bufferAttachments
            for (flag, key) in Self.bufferFlagKeys {
                attachments[key] = newValue.contains(flag) ? true : nil
            }
        }
    }

    /// A buffer without samples that tells the consumer the media ended.
    static func endOfStream() throws(SampleBufferError) -> CMSampleBuffer {
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

    /// Sets how much of the buffer isn't played at its start and at its end. The output time follows the trim at the
    /// start, unless it was set.
    func setTrim(atStart: CMTime, atEnd: CMTime) {
        let attachments = bufferAttachments
        attachments[.trimDurationAtStart] = atStart > .zero
            ? CMTimeCopyAsDictionary(atStart, allocator: kCFAllocatorDefault)
            : nil
        attachments[.trimDurationAtEnd] = atEnd > .zero
            ? CMTimeCopyAsDictionary(atEnd, allocator: kCFAllocatorDefault)
            : nil
    }
}

private extension CMSampleBuffer {
    /// The flags of a sample, each with the attachment that tells it and the value it has then.
    static let sampleFlagKeys: [(SEPlayerCommon.SampleProperties.Flags, PerSampleAttachments.Key, Bool)] = [
        (.keyframe, .notSync, false),
        (.notDependedOn, .isDependedOnByOthers, false),
        (.partialSync, .partialSync, true),
        (.independent, .dependsOnOthers, false),
        (.hasRedundantCoding, .hasRedundantCoding, true),
        (.decodeOnly, .doNotDisplay, true),
        (.displayImmediately, .displayImmediately, true),
        (.allowsEarlierDisplayTimes, .earlierDisplayTimesAllowed, true),
    ]

    /// The flags of a buffer, each with the attachment that is `true` for it.
    static let bufferFlagKeys: [(SEPlayerCommon.SampleProperties.Flags, SampleBufferAttachments.Key)] = [
        (.firstSample, .firstSample),
        (.lastSample, .lastSample),
        (.endOfStream, .permanentEmptyMedia),
        (.resetsDecoder, .resetDecoderBeforeDecoding),
        (.drainsDecoder, .drainAfterDecoding),
    ]

    func attach(_ attributes: SampleAttributes) {
        setTrim(atStart: attributes.trimAtStart, atEnd: attributes.trimAtEnd)

        let sample = perSampleAttachments[0]
        if let level = attributes.temporalLevel {
            sample[.hevcTemporalLevelInfo] = [kCMHEVCTemporalLevelInfoKey_TemporalLevel: level]
        }
        sample[.hevcSyncSampleNALUnitType] = attributes.syncSampleNALUnitType
        switch attributes.temporalSubLayerAccess {
        case .full: sample[.hevcTemporalSubLayerAccess] = true
        case .stepwise: sample[.hevcStepwiseTemporalSubLayerAccess] = true
        case nil: break
        }
        sample[.audioIndependentSampleDecoderRefreshCount] = attributes.audioDecoderRefreshCount
        if #available(iOS 16, tvOS 16, macOS 13, *) {
            sample[PerSampleAttachments.Key(rawValue: kCMSampleAttachmentKey_HDR10PlusPerFrameData)] =
                attributes.hdr10PlusMetadata
        }
    }
}

package extension SampleBufferAttachments.Key {
    static let firstSample = Self(rawValue: "com.seplayer.firstSampleKey" as CFString)
    static let lastSample = Self(rawValue: "com.seplayer.lastSampleKey" as CFString)
}
