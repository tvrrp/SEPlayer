//
//  TextOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 02.10.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.text.TextOutput
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// Receives text output.
public protocol TextOutput: AnyObject {
    /// Called when there is a change in the `CueGroup`.
    ///
    /// Called on the main queue.
    func onCues(_ cueGroup: CueGroup)
}
