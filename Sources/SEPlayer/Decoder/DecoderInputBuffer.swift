//
//  DecoderInputBuffer.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 29.01.2025.
//

import CoreMedia

struct DecoderInputBuffer {
    var bufferFlags: SampleFlags = []
    let format: CMFormatDescription?
    let data: UnsafeMutableRawPointer?

    let sampleTimings: CMSampleTimingInfo
}
