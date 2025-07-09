//
//  SampleMetadata.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.04.2025.
//

import CoreMedia.CMSampleBuffer

struct SampleMetadata {
    let sampleTimings: CMSampleTimingInfo
    let flags: SampleFlags
    let size: Int

    init(duration: CMTime, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, flags: SampleFlags, size: Int) {
        self.sampleTimings = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        self.flags = flags
        self.size = size
    }
}
