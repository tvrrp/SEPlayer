//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol TrackOutput {
    var isolation: any Actor { get }
    func setDuration(_ duration: CMTime, isolation: isolated any Actor)
    func setFormat(_ format: Format, isolation: isolated any Actor) throws
    func sampleData(data: CMBlockBuffer, isolation: isolated any Actor) throws
    func sampleMetadata(time: CMSampleTimingInfo, flags: SampleFlags, range: Range<Int>, isolation: isolated any Actor) throws
}

public extension TrackOutput {
    func setDuration(_ duration: CMTime, isolation: isolated any Actor) {}
}
