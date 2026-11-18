//
//  CMSampleBuffer+Extrensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 31.01.2025.
//

import CoreMedia.CMSampleBuffer
import SEPlayerCommon

extension CMSampleBuffer {
    func nanoseconds(_ value: Int64) throws(SampleBufferError) -> CMSampleBuffer {
        let timings = try sampleTimings().map { oldTiming in
            CMSampleTimingInfo(
                duration: oldTiming.duration,
                presentationTimeStamp: .from(nanoseconds: value),
                decodeTimeStamp: .zero
            )
        }
        return try CMSampleBuffer(copying: self, withNewTiming: timings)
    }
}
