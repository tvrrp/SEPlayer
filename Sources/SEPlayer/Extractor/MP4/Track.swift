//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia

struct Track {
    let id: Int
    let type: TrackType
    let format: TrackFormat
    let timescale: CMTimeScale
    let movieTimescale: CMTimeScale
    let duration: CMTimeValue

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
