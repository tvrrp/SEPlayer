//
//  DecoderReinitializationState.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 05.05.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.video.DecoderVideoRenderer
//    androidx.media3.exoplayer.DecoderReuseEvaluation
//  Copyright (C) 2020 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

/// Whether a decoder can go on after the input format changed.
public enum DecoderReuseResult: Sendable {
    /// The decoder can't decode the new format: it is drained, then released for a decoder of the new format.
    case no
    /// The decoder decodes the new format as it is.
    case yesWithoutReconfiguration
}

/// Where a renderer is in replacing its decoder after a format the decoder can't decode.
enum DecoderReinitializationState {
    /// The decoder is not being replaced.
    case none
    /// The decoder is told next that its input ended, so it outputs every frame it holds.
    case signalEndOfStream
    /// The decoder is outputting what it holds; it is replaced once it finished.
    case waitEndOfStream
}
