//
//  MediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

public protocol MediaClock: AnyObject {
    func setPlaybackParameters(new playbackParameters: PlaybackParameters)
    func getPlaybackParameters() -> PlaybackParameters
    func getPositionUs() -> Int64
}
