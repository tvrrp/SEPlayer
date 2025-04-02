//
//  MediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

protocol MediaClock: AnyObject {
    var playbackParameters: PlaybackParameters { get set }
    func getPosition() -> Int64
}
