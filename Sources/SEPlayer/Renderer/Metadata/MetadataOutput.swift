//
//  MetadataOutput.swift
//  SEPlayer
//
//  Created by tvrrp on 19.11.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.metadata.MetadataOutput
//  Copyright (C) 2017 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import SEPlayerCommon

/// Receives timed metadata: ID3 tags, ICY titles, event messages.
public protocol MetadataOutput: AnyObject {
    /// Called when the playback position reaches the time of `metadata`, its ``Metadata/presentationTime``.
    ///
    /// Called on the main queue.
    func onMetadata(_ metadata: Metadata)
}
