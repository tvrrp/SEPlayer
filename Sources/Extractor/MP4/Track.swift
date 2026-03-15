//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import SEPlayerCommon

public struct Track {
    public let id: Int
    public let type: TrackType
    public var format: Format
    public let timescale: Int64
    public let movieTimescale: Int64
    public let durationUs: Int64
    public let mediaDurationUs: Int64
    public let editListDurations: [Int64]?
    public let editListMediaTimes: [Int64]?
    public let nalUnitLengthFieldLength: Int
}
