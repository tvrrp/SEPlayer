//
//  TrackOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 06.01.2025.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.TrackOutput
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import SEPlayerCommon

/// Where an extractor writes a track: its format, then the bytes and the timing of each sample.
///
/// The extractor calls it from the task that loads, one call at a time, and the output takes each call at once: there are
/// a few for every sample, too many to wait for another queue.
public protocol TrackOutput {
    func setDuration(_ duration: CMTime)
    func setFormat(_ format: AnyFormat) throws
    func sampleData(data: CMBlockBuffer) throws
    /// Tells about a sample whose bytes were written.
    func sampleMetadata(_ properties: SampleProperties) throws
}

public extension TrackOutput {
    func setDuration(_ duration: CMTime) {}
}
