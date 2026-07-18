//
//  CMSampleBuffer+extensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 04.07.2026.
//

import CoreMedia

public extension CMSampleBuffer {
    var flags: SampleFlags {
        var flags = SampleFlags()
        if (sampleAttachments[0][.notSync] as? Bool) == false {
            flags.insert(.keyframe)
        }

        if (sampleAttachments[0][.dependsOnOthers] as? Bool) == false {
            flags.insert(.notDependedOn)
        }

        if (attachments[.firstSample]?.value as? Bool) == true {
            flags.insert(.firstSample)
        }

        if (attachments[.lastSample]?.value as? Bool) == true {
            flags.insert(.lastSample)
        }

        if (attachments[.permanentEmptyMedia]?.value as? Bool) == true {
            flags.insert(.endOfStream)
        }

        return flags
    }

    static func createEndOfStream() throws -> CMSampleBuffer {
        let buffer = try CMSampleBuffer(
            dataBuffer: nil,
            formatDescription: nil,
            numSamples: 0,
            sampleTimings: [],
            sampleSizes: []
        )

        buffer.attachments.merge([
            CMSampleBuffer.AttachmentKey.permanentEmptyMedia.rawValue as String : true
        ], mode: .shouldPropagate)

        return buffer
    }

    func attach(flags: SampleFlags) {
        if !flags.contains(.keyframe) {
            sampleAttachments[0][.notSync] = true
        }

        if flags.contains(.notDependedOn) {
            sampleAttachments[0][.dependsOnOthers] = false
        }

        if flags.contains(.firstSample) {
            attachments.merge([
                CMSampleBuffer.AttachmentKey.firstSample.rawValue as String : true
            ], mode: .shouldPropagate)
        }

        if flags.contains(.lastSample) {
            attachments.merge([
                CMSampleBuffer.AttachmentKey.firstSample.rawValue as String : true
            ], mode: .shouldPropagate)
        }

        if flags.contains(.endOfStream) {
            attachments.merge([
                CMSampleBuffer.AttachmentKey.permanentEmptyMedia.rawValue as String : true
            ], mode: .shouldPropagate)
        }
    }
}

private extension CMSampleBuffer.AttachmentKey {
    static let firstSample = CMSampleBuffer.AttachmentKey(
        rawValue:"com.seplayer.firstSampleKey" as CFString
    )

    static let lastSample = CMSampleBuffer.AttachmentKey(
        rawValue:"com.seplayer.lastSampleKey" as CFString
    )
}
