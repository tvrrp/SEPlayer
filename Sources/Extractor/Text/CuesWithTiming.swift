//
//  CuesWithTiming.swift
//  SEPlayer
//
//  Created by tvrrp on 24.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.text.CuesWithTiming
//  Copyright (C) 2023 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// A list of `Cue` instances with a start time and duration.
public struct CuesWithTiming {
    /// The cues to show on screen.
    public let cues: [Cue]

    /// The time at which `cues` should be shown on screen, or `.invalid` if not known.
    ///
    /// The time base of this depends on the context from which this instance was obtained.
    public let startTime: CMTime

    /// The duration for which `cues` should be shown on screen, or `.invalid` if not known.
    ///
    /// If `CueReplacementBehavior` is `.merge` then cues from multiple instances will be shown on screen
    /// simultaneously if their start times and durations overlap.
    ///
    /// `.invalid` is only permitted if the `CueReplacementBehavior` of the current track is `.replace`.
    public let duration: CMTime

    /// The time at which `cues` should stop being shown on screen, or `.invalid` if not known.
    ///
    /// The time base of this is the same as `startTime`.
    ///
    /// If `CueReplacementBehavior` is `.merge` then cues from multiple instances will be shown on screen
    /// simultaneously if their start and times overlap.
    ///
    /// `.invalid` is only permitted if the `CueReplacementBehavior` of the current track is `.replace`.
    public let endTime: CMTime

    /// Creates an instance.
    public init(cues: [Cue], startTime: CMTime, duration: CMTime) {
        self.cues = cues
        self.startTime = startTime
        self.duration = duration
        self.endTime = if startTime.isValid, duration.isValid {
            startTime + duration
        } else {
            .invalid
        }
    }
}
