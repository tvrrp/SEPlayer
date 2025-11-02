//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

struct Track {
    let id: Int
    let type: TrackType
    var format: Format
    let timescale: Int64
    let movieTimescale: Int64
    let durationUs: Int64
    let mediaDurationUs: Int64
    let editListDurations: [Int64]?
    let editListMediaTimes: [Int64]?
}
