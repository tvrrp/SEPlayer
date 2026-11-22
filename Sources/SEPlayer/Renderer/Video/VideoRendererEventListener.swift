//
//  VideoRendererEventListener.swift
//  SEPlayer
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.video.VideoRendererEventListener
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// Hears what a video renderer shows. Called on the queue of the renderer.
public protocol VideoRendererEventListener: AnyObject {
    /// Called when the size of the video changes: when the first frame of the new size is queued to show.
    func onVideoSizeChanged(_ videoSize: VideoSize)

    /// Called when a frame shows for the first time since the renderer was enabled, or since its position was reset.
    func onRenderedFirstFrame()

    /// Called when the format the renderer reads changes, a moment before it shows; `nil` once it is disabled.
    func onVideoInputFormatChanged(_ format: AnyFormat?)
}

/// Hears what an audio renderer plays. Called on the queue of the renderer.
public protocol AudioRendererEventListener: AnyObject {
    /// Called when the format the renderer reads changes, a moment before it plays; `nil` once it is disabled.
    func onAudioInputFormatChanged(_ format: AnyFormat?)
}
