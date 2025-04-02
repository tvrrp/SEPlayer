//
//  PlaybackParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.04.2025.
//

struct PlaybackParameters: Hashable {
    let playbackRate: Float

    static let `default` = PlaybackParameters(playbackRate: 1.0)

    func mediaTimeForPlaybackRate(_ position: Int64) -> Int64 {
        Int64(Double(position) * Double(playbackRate))
    }
}
