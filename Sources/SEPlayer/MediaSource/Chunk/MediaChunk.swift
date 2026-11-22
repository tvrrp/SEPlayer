//
//  MediaChunk.swift
//  SEPlayer
//
//  Created by tvrrp on 23.02.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.exoplayer.source.chunk.MediaChunk
//  Copyright (C) 2016 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import DataSource
import SEPlayerCommon

/// An abstract base class for ``Chunk``s that contain media samples.
open class MediaChunk: Chunk, @unchecked Sendable {
    /// The chunk index, or `nil` if it is not known.
    public let chunkIndex: Int?

    /// The next chunk index, or `nil` if it is not known.
    open var nextChunkIndex: Int? {
        chunkIndex.map { $0 + 1 }
    }

    public init(
        dataSpec: DataSpec,
        trackFormat: AnyFormat,
        trackSelectionReason: TrackSelectionReason,
        trackSelectionData: Any?,
        startTime: CMTime,
        endTime: CMTime,
        chunkIndex: Int?
    ) {
        self.chunkIndex = chunkIndex
        super.init(
            dataSpec: dataSpec,
            dataType: .media,
            trackFormat: trackFormat,
            trackSelectionReason: trackSelectionReason,
            trackSelectionData: trackSelectionData,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// Whether the chunk has been fully loaded.
    open var isLoadCompleted: Bool { fatalError("To override") }
}
