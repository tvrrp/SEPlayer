//
//  MediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//

import CoreMedia
import SEPlayerCommon

public protocol MediaClock: AnyObject {
    func setPlaybackParameters(new playbackParameters: PlaybackParameters) throws
    func getPlaybackParameters() -> PlaybackParameters
    func getPosition() -> CMTime
}
