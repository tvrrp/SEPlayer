//
//  MediaChunkIterator.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.chunk.MediaChunkIterator
//  Copyright (C) 2018 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import DataSource

public protocol MediaChunkIterator {
    var isEnded: Bool { get }
    var dataSpec: DataSpec? { get }
    var chunkStartTimeUs: Int64? { get }
    var chunkEndTimeUs: Int64? { get }
    func next() throws -> Bool
    func reset()
}

struct EmptyMediaChunkIterator: MediaChunkIterator {
    let isEnded = true
    let dataSpec: DataSpec? = nil
    let chunkStartTimeUs: Int64? = nil
    let chunkEndTimeUs: Int64? = nil

    func next() throws -> Bool { false }
    func reset() {}
}
