//
//  Track.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//

import CoreMedia
import CoreVideo
import CoreAudio

struct Track {
    let id: Int
    let type: TrackType
    let formats: [TrackFormat]
    let timescale: Int
    let movieTimescale: Int
    let duration: Int

    enum TrackFormat {
        case video(CMVideoFormatDescription)
        case audio(CMAudioFormatDescription)
        
        var format: CMFormatDescription {
            switch self {
            case let .video(videoFormat):
                return videoFormat
            case let .audio(audioFormat):
                return audioFormat
            }
        }
    }

    init(id: Int, type: TrackType, formats: [TrackFormat], timescale: Int, movieTimescale: Int, duration: Int) {
        self.id = id
        self.type = type
        self.formats = formats
        self.timescale = timescale
        self.movieTimescale = movieTimescale
        self.duration = duration
    }
}
