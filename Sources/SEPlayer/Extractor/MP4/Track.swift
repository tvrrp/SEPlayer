//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia.CMFormatDescription

struct Track {
    let id: Int
    let type: TrackType
    let format: TrackFormat
    let timescale: Int64
    let movieTimescale: Int64
    let durationUs: Int64
    let mediaDurationUs: Int64

    enum TrackFormat {
        case video(CMVideoFormatDescription)
        case audio(CMAudioFormatDescription)

        var formatDescription: CMFormatDescription {
            switch self {
            case let .video(videoFormat):
                return videoFormat
            case let .audio(audioFormat):
                return audioFormat
            }
        }
    }
}
