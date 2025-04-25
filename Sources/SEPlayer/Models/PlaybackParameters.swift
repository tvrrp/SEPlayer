//
//  PlaybackParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.04.2025.
//

struct PlaybackParameters: Hashable {
    let playbackRate: Float
    let pitch: Float

    init(playbackRate: Float, pitch: Int = 1200) {
        self.playbackRate = playbackRate
        self.pitch = Float(max(-2400, min(2400, pitch)))
    }

    static let `default` = PlaybackParameters(playbackRate: 1.0, pitch: 1)

    func mediaTimeForPlaybackRate(_ position: Int64) -> Int64 {
        Int64(Double(position) * Double(playbackRate))
    }
}
