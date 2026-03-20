//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import SEPlayerCommon

public struct Track {
    public let id: Int
    public let type: TrackType
    public var format: Format
    public let timescale: CMTimeScale
    public let movieTimescale: CMTimeScale
    public let duration: CMTime
    public let mediaDuration: CMTime
    public let editListDurations: [Int64]?
    public let editListMediaTimes: [Int64]?
    public let nalUnitLengthFieldLength: Int
 
    // Backward-compatible microsecond accessors (derived from CMTime).
    public var durationUs: Int64 {
        duration.isValid ? duration.microseconds : .timeUnset
    }
    public var mediaDurationUs: Int64 {
        mediaDuration.isValid ? mediaDuration.microseconds : .timeUnset
    }
}
