//
//  MediaClock.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 01.03.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.MediaClock
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

public protocol MediaClock: AnyObject {
    func setPlaybackParameters(new playbackParameters: PlaybackParameters) throws
    func getPlaybackParameters() -> PlaybackParameters
    func getPosition() -> CMTime
}
