//
//  CeaUtil.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 15.08.2026.
//

import CoreMedia
import SEPlayerCommon

enum CeaUtil {
    /// Consumes the unescaped content of an SEI NAL unit, writing the content of any CEA-608/708
    /// messages as samples to all of the provided outputs.
    /// - Parameters:
    ///   - presentationTime: The presentation time for any samples.
    ///   - seiBuffer: The unescaped SEI NAL unit data, excluding the NAL unit start code and type.
    ///   - outputs: The outputs to which any samples should be written.
    static func consume(
        presentationTime: CMTime,
        seiBuffer: inout BlockBufferReader,
        outputs: [TrackOutput]
    ) throws {}

    /// Consumes caption data (cc_data), writing the content as samples to all of the provided outputs.
    /// - Parameters:
    ///   - presentationTime: The presentation time for any samples.
    ///   - ccDataBuffer: The buffer containing the caption data.
    ///   - outputs: The outputs to which any samples should be written.
    static func consumeCcData(
        presentationTime: CMTime,
        ccDataBuffer: inout BlockBufferReader,
        outputs: [TrackOutput]
    ) throws {}
}
