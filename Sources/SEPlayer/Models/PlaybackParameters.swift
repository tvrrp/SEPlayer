//
//  PlaybackParameters.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 02.04.2025.
//

public struct PlaybackParameters: Hashable {
    public private(set) var playbackRate: Float
    public let pitch: Float

    public init(playbackRate: Float, pitch: Int = 1200) {
        self.playbackRate = playbackRate
        self.pitch = Float(max(-2400, min(2400, pitch)))
    }

    public static let `default` = PlaybackParameters(playbackRate: 1.0, pitch: 1)

    internal func mediaTimeForPlaybackRate(_ position: Int64) -> Int64 {
        Int64(Double(position) * Double(playbackRate))
    }

    public mutating func newSpeed(_ playbackRate: Float) {
        self.playbackRate = playbackRate
    }
}
