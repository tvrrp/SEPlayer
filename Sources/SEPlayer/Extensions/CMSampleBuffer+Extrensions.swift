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

    enum Errors: OSStatus {
        case allocationFailed = -12730
        case requiredParameterMissing = -12731
        case alreadyHasDataBuffer = -12732
        case bufferNotReady = -12733
        case sampleIndexOutOfRange = -12734
        case bufferHasNoSampleSizes = -12735
        case bufferHasNoSampleTimingInfo = -12736
        case arrayTooSmall = -12737
        case invalidEntryCount = -12738
        case cannotSubdivide = -12739
        case sampleTimingInfoInvalid = -12740
        case invalidMediaTypeForOperation = -12741
        case invalidSampleData = -12742
        case invalidMediaFormat = -12743
        case invalidated = -12744
        case dataFailed = -16750
        case dataCanceled = -16751
    }
}
