//
//  CMSampleBuffer+Extrensions.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 31.01.2025.
//

import CoreMedia

extension CMSampleBuffer {
    func nanoseconds(_ value: Int64) throws -> CMSampleBuffer {
        try CMSampleBuffer(
            copying: self,
            withNewTiming: self.sampleTimingInfos().map { oldTiming in
                CMSampleTimingInfo(
                    duration: oldTiming.duration,
                    presentationTimeStamp: .from(nanoseconds: value),
                    decodeTimeStamp: .zero
                )
            }
        )
    }
}
