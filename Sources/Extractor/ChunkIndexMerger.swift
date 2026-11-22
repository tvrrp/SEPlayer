//
//  ChunkIndexMerger.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 10.08.2026.
//
//  Derived from AndroidX Media3 (https://github.com/androidx/media):
//    androidx.media3.extractor.ChunkIndexMerger
//  Copyright (C) 2025 The Android Open Source Project
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//  Changed from the original: translated to Swift and adapted to SEPlayer.
//

import CoreMedia
import OrderedCollections
import SEPlayerCommon

struct ChunkIndexMerger {
    var count: Int { chunkMap.count }

    private var chunkMap = OrderedDictionary<CMTime, ChunkIndex>()

    mutating func add(_ chunk: ChunkIndex) {
        if !chunk.times.isEmpty, !chunkMap.keys.contains(chunk.times[0]) {
            chunkMap[chunk.times[0]] = chunk
        }
    }

    func merge() -> ChunkIndex {
        ChunkIndex(
            sizes: chunkMap.values.flatMap { $0.sizes },
            offsets: chunkMap.values.flatMap { $0.offsets },
            durations: chunkMap.values.flatMap { $0.durations },
            times: chunkMap.values.flatMap { $0.times }
        )
    }

    mutating func clear() {
        chunkMap.removeAll()
    }
}
