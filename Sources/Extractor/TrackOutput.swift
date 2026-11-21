//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

/// Where an extractor writes a track: its format, then the bytes and the timing of each sample.
///
/// The extractor calls it from the task that loads, one call at a time, and the output takes each call at once: there are
/// a few for every sample, too many to wait for another queue.
public protocol TrackOutput {
    func setDuration(_ duration: CMTime)
    func setFormat(_ format: AnyFormat) throws
    func sampleData(data: CMBlockBuffer) throws
    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>) throws
}

public extension TrackOutput {
    func setDuration(_ duration: CMTime) {}
}
